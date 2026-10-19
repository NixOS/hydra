//! Submitting one evaluation of one jobset.
//!
//! Fetch the inputs, decide whether they have been evaluated before, and if
//! not queue a build that will run `nix-eval-jobs` over them. That is where
//! this half ends: the evaluation is finished when that build is, and reading
//! it back is `hydra-process-evaluation`'s job.

use color_eyre::eyre::{self, WrapErr as _};
use sha2::{Digest as _, Sha256};

use crate::config::HydraConfig;
use crate::declarative;
use crate::eval_build;
use crate::fetcher::InputFetcher;
use crate::inputs::{self, ConfiguredInput, InputInfo};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries::{self, NewEval};
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
    let meta = queries::get_jobset_for_eval(&mut conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;
    let meta_id = meta.id;

    // One worker fetches every plugin input this evaluation needs, the
    // declarative specification's included. The plugins add a temp root for
    // each path they fetch, but those roots belong to the worker and last
    // only as long as it does, so it is kept until the evaluation derivation,
    // which refers to the inputs, is queued.
    let mut fetcher = InputFetcher::start()?;
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
    meta: queries::JobsetForEval,
    trace: &str,
) -> eyre::Result<Outcome> {
    // `.jobsets` is Hydra evaluating a declarative project's own
    // configuration. The specification may name the jobsets outright, in
    // which case they are created and this is done; or it may describe how
    // to generate them, in which case it reconfigures this jobset, which is
    // then evaluated with the specification's input and the project's name
    // besides its own.
    let mut extra_inputs = InputInfo::new();
    let mut extra_configured = Vec::new();
    if let Some(declfile) = meta.declfile.as_deref().filter(|f| !f.is_empty())
        && jobset == ".jobsets"
    {
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
        if declarative::apply(project, &spec_file).await? {
            return Ok(Outcome::Declared);
        }
        extra_configured.push(ConfiguredInput {
            name: "projectName".to_owned(),
            r#type: "string".to_owned(),
            value: Some(project.to_owned()),
            email_responsible: false,
        });
    }
    // Re-read, since a specification may have changed what to evaluate.
    let meta = queries::get_jobset_for_eval(conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;

    conn.notify_eval_started(trace, meta.id).await?;

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

    let mut resolved =
        inputs::resolve(conn, fetcher, available, project, jobset, &configured).await?;
    resolved.extend(extra_inputs);
    let checkout_time = checkout_start.elapsed().as_secs();

    let expr = Expression {
        flake: meta.flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };
    let cmd = nix_eval_jobs::command(available.store_dir(), config, &resolved, &expr)?;

    // The hash covers the arguments, so it changes exactly when what would be
    // evaluated changes. If the previous evaluation used the same ones there
    // is nothing to learn by running it again.
    let hash = hex::encode(Sha256::digest(cmd.join(" ").as_bytes()));
    if let Some(previous) = queries::get_previous_eval(conn, meta.id).await?
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && meta.flake.as_deref() == previous.flake.as_deref()
    {
        conn.notify_eval_cached(trace, meta.id, previous.id).await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    let name = format!("{project}:{jobset}");
    let store_dir = available.store_dir().to_path().display().to_string();
    let drv_path =
        eval_build::instantiate(config, &resolved, "nix-eval-jobs", &cmd, &name, &store_dir)
            .await
            .wrap_err("failed to instantiate the evaluation derivation")?;

    let eval_jobset = queries::ensure_eval_jobset(conn).await?;
    let system = current_system().await?;

    let mut tx = conn.begin_transaction().await?;
    let build =
        queries::insert_eval_build(&mut tx, eval_jobset, &name, &drv_path, &system, now()).await?;
    let eval = queries::insert_eval(
        &mut tx,
        &NewEval {
            jobset_id: meta.id,
            checkout_time: i32::try_from(checkout_time).unwrap_or(0),
            hash: &hash,
            flake: meta.flake.as_deref(),
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
                &store_dir,
            )
            .await?;
        }
    }
    tx.commit().await?;

    Ok(Outcome::Scheduled { eval, build })
}

/// The system the evaluation build should be scheduled for.
async fn current_system() -> eyre::Result<String> {
    let out = tokio::process::Command::new("nix-instantiate")
        .args(["--eval", "-E", "builtins.currentSystem"])
        .output()
        .await
        .wrap_err("could not ask nix for the current system")?;
    eyre::ensure!(
        out.status.success(),
        "could not ask nix for the current system"
    );
    Ok(String::from_utf8_lossy(&out.stdout)
        .trim()
        .trim_matches('"')
        .to_owned())
}
