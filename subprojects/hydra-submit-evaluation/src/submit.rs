//! Submitting one evaluation of one jobset.
//!
//! Fetch the inputs, decide whether they have been evaluated before, and if
//! not queue a build that will run `nix-eval-jobs` over them. That is where
//! this half ends: the evaluation is finished when that build is, and reading
//! it back is `hydra-process-evaluation`'s job.

use color_eyre::eyre::{self, WrapErr as _};

use crate::config::HydraConfig;
use crate::declarative;
use crate::eval_build;
use crate::fetcher::InputFetcher;
use crate::inputs::{self, ConfiguredInput, InputInfo};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries::{self, JobsetForEval, NewEval};
use crate::scheduler::now;
use crate::store_paths::Availability;

/// What submitting produced.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// An evaluation was queued as a build.
    Scheduled { eval: i32, build: i32 },
    /// A declarative project whose specification named its jobsets outright,
    /// so they were created and there was nothing to evaluate.
    Declared,
    /// An input could not be fetched. The error goes in the jobset's fetch
    /// error, and its evaluation error stays as it was.
    FetchFailed,
}

impl Outcome {
    /// Whether `hydra-submit-evaluation <project> <jobset>` should exit
    /// successfully.
    pub(crate) fn succeeded(self) -> bool {
        !matches!(self, Self::FetchFailed)
    }
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cached { previous } => write!(f, "cached, same as evaluation {previous}"),
            Self::Scheduled { eval, build } => {
                write!(f, "scheduled evaluation {eval} as build {build}")
            }
            Self::Declared => f.write_str("jobsets created from the declarative specification"),
            Self::FetchFailed => f.write_str("could not fetch its inputs"),
        }
    }
}

/// Submit an evaluation, recording the outcome on the jobset either way.
pub(crate) async fn submit(
    db: &db::Database,
    config: &HydraConfig,
    available: &Availability,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let started = now();
    let mut conn = db.get().await?;
    let meta = get_jobset(&mut conn, project, jobset).await?;
    let meta_id = meta.id;

    conn.notify_eval_started(trace, meta_id).await?;

    // One worker fetches every plugin input this evaluation needs, the
    // declarative specification's included. The plugins add a temp root for
    // each path they fetch, but those roots belong to the worker and last
    // only as long as it does, so it is kept until the evaluation derivation,
    // which refers to the inputs, is queued.
    let mut fetcher = InputFetcher::new(&available.programs().fetch_input);
    let result = schedule(
        &mut conn,
        &mut fetcher,
        config,
        available,
        project,
        jobset,
        meta,
        trace,
    )
    .await;
    fetcher.shutdown().await;

    match &result {
        Ok(Outcome::Declared) => {
            queries::record_declared(&mut conn, meta_id, started, now()).await?;
        }
        Ok(_) => queries::record_checked(&mut conn, meta_id, started, now()).await?,
        Err(e) => {
            queries::record_failed(&mut conn, trace, meta_id, &format!("{e:#}"), started, now())
                .await?;
        }
    }
    result
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
async fn schedule(
    conn: &mut db::Connection,
    fetcher: &mut InputFetcher,
    config: &HydraConfig,
    available: &Availability,
    project: &str,
    jobset: &str,
    meta: JobsetForEval,
    trace: &str,
) -> eyre::Result<Outcome> {
    // `.jobsets` is Hydra evaluating a declarative project's own
    // configuration. The specification may name the jobsets outright, in
    // which case they are created and this is done; or it may describe how
    // to generate them, in which case it reconfigures this jobset, which is
    // then evaluated with the specification's input and the project's name
    // besides its own.
    let jobsets_jobset =
        jobset == ".jobsets" && meta.declfile.as_deref().is_some_and(|f| !f.is_empty());
    let mut extra_inputs = InputInfo::new();
    let mut extra_configured = Vec::new();
    if jobsets_jobset {
        let declfile = meta.declfile.as_deref().unwrap_or_default();
        let decl = ConfiguredInput {
            name: "declInput".to_owned(),
            r#type: meta.decltype.clone().unwrap_or_default(),
            value: meta.declvalue.clone(),
            email_responsible: false,
        };
        extra_inputs = inputs::resolve(conn, fetcher, available, project, jobset, &[decl]).await?;
        let [decl_input] = extra_inputs["declInput"].as_slice() else {
            eyre::bail!(
                "the input containing the declarative project specification must have \
                 exactly one alternative"
            );
        };
        let store_path = decl_input.store_path.as_deref().unwrap_or_default();
        let spec_file = format!(
            "{}/{declfile}",
            nix_eval_jobs::full(available.store_dir(), store_path)
        );
        if declarative::apply(
            &available.programs().prepare_declarative_jobset,
            project,
            &spec_file,
        )
        .await?
        {
            return Ok(Outcome::Declared);
        }
        extra_configured.push(ConfiguredInput {
            name: "projectName".to_owned(),
            r#type: "string".to_owned(),
            value: Some(project.to_owned()),
            email_responsible: false,
        });
    }
    // Re-read, since the specification may have changed what to evaluate.
    let meta = if jobsets_jobset {
        get_jobset(conn, project, jobset).await?
    } else {
        meta
    };

    // Fetching is the slow part and the part that talks to the world, so it
    // happens before anything is written and outside any transaction.
    let checkout_start = std::time::Instant::now();
    let configured: Vec<ConfiguredInput> = queries::get_jobset_inputs(conn, project, jobset)
        .await?
        .into_iter()
        .map(|row| ConfiguredInput {
            name: row.name,
            r#type: row.r#type,
            value: row.value,
            email_responsible: row.emailresponsible != 0,
        })
        .chain(extra_configured)
        .collect();

    let resolution = inputs::resolve(conn, fetcher, available, project, jobset, &configured).await;

    // Lock the flake so the evaluation runs on, and records, one fixed
    // revision. As in the Perl, a flake that cannot be locked fails the
    // evaluation even when an input also failed to fetch.
    let flake = match meta.flake.as_deref() {
        Some(flake) => Some(lock_flake(&available.programs().nix, flake).await?),
        None => None,
    };
    let checkout_time = checkout_start.elapsed().as_secs();

    let mut resolved = match resolution {
        Ok(resolved) => resolved,
        Err(e) => {
            let message = format!("{e:#}");
            let mut tx = conn.begin_transaction().await?;
            queries::set_fetch_error(&mut tx, meta.id, Some(&message)).await?;
            // A fetch error leaves `errormsg` unchanged, so the notification
            // says the error did not change and nobody is mailed.
            tx.notify_eval_failed(trace, meta.id, false).await?;
            tx.commit().await?;
            return Ok(Outcome::FetchFailed);
        }
    };
    resolved.extend(extra_inputs);
    let mut tx = conn.begin_transaction().await?;
    queries::set_fetch_error(&mut tx, meta.id, None).await?;
    tx.commit().await?;

    let expr = Expression {
        flake: flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };

    // If the latest evaluation had the same inputs there is nothing to learn
    // by running it again. A flake is compared by its locked reference.
    let hash = nix_eval_jobs::input_hash(available.store_dir(), &resolved, &expr)?;
    if let Some(previous) = queries::get_latest_eval(conn, meta.id).await?
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && (flake.is_none() || previous.flake == flake)
    {
        conn.notify_eval_cached(trace, meta.id, previous.id).await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    let cmd = nix_eval_jobs::command(available.store_dir(), config, &resolved, &expr)?;
    let name = format!("{project}:{jobset}");
    let store_dir = available.store_dir();
    let drv_path = eval_build::instantiate(
        config,
        available.programs(),
        &resolved,
        &cmd,
        &name,
        &store_dir.to_path().display().to_string(),
    )
    .await
    .wrap_err("failed to instantiate the evaluation derivation")?;

    let eval_jobset = queries::ensure_eval_jobset(conn).await?;
    let system = current_system(available).await?;

    let mut tx = conn.begin_transaction().await?;
    let build = queries::insert_eval_build(
        &mut tx,
        eval_jobset,
        &name,
        &drv_path,
        &system,
        i32::try_from(config.eval_timeout()).unwrap_or(i32::MAX),
        now(),
    )
    .await?;
    let eval = queries::insert_eval(
        &mut tx,
        &NewEval {
            jobset_id: meta.id,
            checkout_time: i32::try_from(checkout_time).unwrap_or(0),
            hash: &hash,
            flake: flake.as_deref(),
            nix_expr_input: meta.nixexprinput.as_deref(),
            nix_expr_path: meta.nixexprpath.as_deref(),
            eval_build: build,
            trace_id: trace,
        },
        now(),
    )
    .await?;

    // The inputs are recorded now because this is when they are known:
    // completion happens later, and re-fetching could see other revisions.
    for (name, alts) in &resolved {
        for (n, alt) in alts.iter().enumerate() {
            queries::insert_eval_input(
                &mut tx,
                eval,
                name,
                i32::try_from(n).unwrap_or(0),
                alt,
                store_dir,
            )
            .await?;
        }
    }
    queries::disable_one_shot(&mut tx, meta.id).await?;
    tx.commit().await?;

    Ok(Outcome::Scheduled { eval, build })
}

async fn get_jobset(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
) -> eyre::Result<JobsetForEval> {
    queries::get_jobset_for_eval(conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))
}

/// Lock a flake reference with `nix flake metadata`, returning the locked
/// reference.
async fn lock_flake(nix: &hydra_programs::NixPath, flake: &str) -> eyre::Result<String> {
    #[derive(serde::Deserialize)]
    struct Metadata {
        url: String,
    }

    let out = crate::run_with_timeout(
        tokio::process::Command::new(nix)
            .args(["flake", "metadata", "--refresh", "--json", "--"])
            .arg(flake),
    )
    .await
    .wrap_err("failed to run 'nix flake metadata'")?;
    if !out.status.success() {
        let stderr = String::from_utf8(out.stderr)
            .wrap_err("'nix flake metadata' wrote non-UTF-8 to stderr")?;
        eyre::bail!(
            "'nix flake metadata' failed: {}:\n{}",
            out.status,
            if stderr.is_empty() {
                "(no output)"
            } else {
                &stderr
            }
        );
    }
    let metadata: Metadata = serde_json::from_slice(&out.stdout)
        .wrap_err("'nix flake metadata' sent unreadable JSON")?;
    Ok(metadata.url)
}

/// The system the evaluation build should be scheduled for.
async fn current_system(available: &Availability) -> eyre::Result<String> {
    let out = crate::run_with_timeout(
        tokio::process::Command::new(&available.programs().nix_instantiate).args([
            "--eval",
            "-E",
            "builtins.currentSystem",
        ]),
    )
    .await
    .wrap_err("could not ask nix for the current system")?;
    eyre::ensure!(
        out.status.success(),
        "could not ask nix for the current system"
    );
    Ok(String::from_utf8(out.stdout)
        .wrap_err("nix printed a non-UTF-8 system")?
        .trim()
        .trim_matches('"')
        .to_owned())
}
