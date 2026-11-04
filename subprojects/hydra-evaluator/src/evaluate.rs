//! Evaluating one jobset, end to end.
//!
//! Fetch the inputs, decide whether they have been evaluated before, run
//! `nix-eval-jobs` over them, and record what it found. The pieces live in
//! their own modules; this is the order they happen in and the decisions
//! between them.

use std::collections::HashMap;
use std::path::PathBuf;

use color_eyre::eyre::{self, WrapErr as _};

use crate::config::HydraConfig;
use crate::declarative;
use crate::fetcher::InputFetcher;
use crate::ingest;
use crate::inputs::{self, ConfiguredInput, InputInfo};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries;
use crate::queries::{JobsetForEval, NewEval};

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// How many times to try work that Postgres aborts to break a lock cycle with
/// the queue runner. The Perl used the same limit.
const CONFLICT_ATTEMPTS: u64 = 10;

/// Await `$work` again when Postgres aborted it to break a deadlock or a
/// serialization conflict. It must be safe to repeat.
///
/// This is a macro because a function taking an async closure that borrows
/// the connection makes the evaluation's future not `Send`.
macro_rules! retry_on_conflict {
    ($what:literal, $work:expr) => {{
        let mut attempt = 0;
        loop {
            attempt += 1;
            let result: eyre::Result<_> = $work.await;
            match result {
                Err(e) if attempt < CONFLICT_ATTEMPTS && is_conflict(&e) => {
                    tracing::warn!("{} aborted (attempt {attempt}), retrying: {e:#}", $what);
                    tokio::time::sleep(std::time::Duration::from_secs(attempt)).await;
                }
                result => break result,
            }
        }
    }};
}

/// What evaluating a jobset produced.
#[derive(Debug)]
pub(crate) enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// The evaluation ran and was recorded.
    Evaluated { eval: i32, changed: bool },
    /// A declarative project whose specification named its jobsets outright,
    /// so they were created and there was nothing to evaluate.
    Declared,
    /// An input could not be fetched. The error goes in the jobset's fetch
    /// error, and its evaluation error stays as it was.
    FetchFailed,
}

#[allow(clippy::too_many_lines)]
pub(crate) async fn evaluate(
    db: &db::Database,
    config: &HydraConfig,
    available: &crate::store_paths::Availability,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let mut conn = db.get().await?;
    let meta = get_jobset(&mut conn, project, jobset).await?;

    conn.notify_eval_started(trace, meta.id).await?;

    // One worker fetches every plugin input this evaluation needs, the
    // declarative specification's included.
    let mut fetcher = InputFetcher::start()?;

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
        extra_inputs =
            inputs::resolve(&mut conn, &mut fetcher, available, project, jobset, &[decl]).await?;
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
            fetcher.shutdown().await;
            queries::set_jobset_error(conn.raw(), meta.id, "", jiff::Timestamp::now().as_second())
                .await?;
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
    let meta = get_jobset(&mut conn, project, jobset).await?;

    // Fetching is the slow part and the part that talks to the world, so it
    // happens before anything is written and outside any transaction.
    let checkout_start = std::time::Instant::now();
    let configured: Vec<ConfiguredInput> = queries::get_jobset_inputs(&mut conn, project, jobset)
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

    let resolution = inputs::resolve(
        &mut conn,
        &mut fetcher,
        available,
        project,
        jobset,
        &configured,
    )
    .await;

    // Lock the flake so the evaluation runs on, and records, one fixed
    // revision. As in the Perl, a flake that cannot be locked fails the
    // evaluation even when an input also failed to fetch.
    let flake = match meta.flake.as_deref() {
        Some(flake) => Some(lock_flake(flake).await?),
        None => None,
    };
    let checkout_time = checkout_start.elapsed().as_secs();

    let mut resolved = match resolution {
        Ok(resolved) => resolved,
        Err(e) => {
            fetcher.shutdown().await;
            let message = format!("{e:#}");
            tracing::warn!("({project}:{jobset}) {message}");
            let mut tx = conn.begin_transaction().await?;
            queries::set_fetch_error(tx.raw(), meta.id, Some(&message)).await?;
            // A fetch error leaves `errormsg` unchanged, so the notification
            // says the error did not change and nobody is mailed.
            tx.notify_eval_failed(trace, meta.id, false).await?;
            tx.commit().await?;
            return Ok(Outcome::FetchFailed);
        }
    };
    resolved.extend(extra_inputs);

    let expr = Expression {
        flake: flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };
    let hash = nix_eval_jobs::input_hash(available.store_dir(), &resolved, &expr)?;

    if let Some(previous) = queries::get_previous_eval(&mut conn, meta.id, false).await?
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && (flake.is_none() || previous.flake == flake)
    {
        fetcher.shutdown().await;
        tracing::info!("({project}:{jobset}) already evaluated these inputs");
        let mut tx = conn.begin_transaction().await?;
        queries::set_fetch_error(tx.raw(), meta.id, None).await?;
        tx.notify_eval_cached(trace, meta.id, previous.id).await?;
        tx.commit().await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    tracing::info!("({project}:{jobset}) evaluating");
    let cmd = nix_eval_jobs::command(available.store_dir(), config, &resolved, &expr)?;
    let eval_start = std::time::Instant::now();
    let jobs = nix_eval_jobs::run(&cmd, &gc_roots_dir(config.roots_dir())?).await?;
    let eval_time = eval_start.elapsed().as_secs();

    // Compare jobs against the last evaluation that had new builds, because
    // an evaluation without new builds records no members.
    let previous = queries::get_previous_eval(&mut conn, meta.id, true).await?;
    let prev_member_count = match &previous {
        Some(p) => Some(queries::count_eval_members(&mut conn, p.id).await?),
        None => None,
    };

    let store_dir = available.store_dir().to_path().display().to_string();
    let new_eval = NewEval {
        jobset_id: meta.id,
        checkout_time: i32::try_from(checkout_time).unwrap_or(0),
        eval_time: i32::try_from(eval_time).unwrap_or(0),
        hash: &hash,
        flake: flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
        evaluation_error_id: None,
    };
    let error_time = jiff::Timestamp::now().as_second();
    let recorded = retry_on_conflict!("the evaluation transaction", async {
        let mut tx = conn.begin_transaction().await?;
        let error_id = queries::insert_evaluation_error(&mut tx, error_time).await?;
        let recorded = ingest::record(
            &mut tx,
            meta.id,
            trace,
            &NewEval {
                evaluation_error_id: Some(error_id),
                ..new_eval
            },
            error_id,
            meta.errormsg.as_deref().unwrap_or_default(),
            &jobs,
            previous.as_ref().map(|p| p.id),
            prev_member_count,
            &resolved,
            &store_dir,
            jobsets_jobset,
        )
        .await
        .wrap_err("failed to record the evaluation")?;
        // `record` compared the new error with the jobset's old one when it
        // announced the evaluation, so the new error is written only now.
        queries::finish_jobset_eval(tx.raw(), meta.id).await?;
        queries::set_jobset_error(tx.raw(), meta.id, &recorded.error, error_time).await?;
        tx.commit().await?;
        Ok(recorded)
    })?;

    // The plugins add a temp root for each path they fetch, but those roots
    // belong to the worker and last only as long as it does. Keep it until
    // evaluation is done with the inputs.
    fetcher.shutdown().await;

    // Both of these touch every build of the jobset, so they run afterwards:
    // holding those row locks for the evaluation's duration deadlocks against
    // the queue runner finishing builds.
    retry_on_conflict!("repointing builds", repoint(&mut conn, &recorded.repoints))
        .wrap_err("failed to repoint builds at their new derivations")?;

    // The current builds are this evaluation's if it changed anything, and
    // otherwise still those of the last one that did.
    let current = if recorded.jobset_changed {
        Some(recorded.eval)
    } else {
        previous.as_ref().map(|p| p.id)
    };
    if let Some(current) = current {
        retry_on_conflict!("marking builds current", async {
            Ok(queries::mark_current(&mut conn, meta.id, current, CURRENT_BATCH).await?)
        })
        .wrap_err("failed to mark this evaluation's builds current")?;
    }

    Ok(Outcome::Evaluated {
        eval: recorded.eval,
        changed: recorded.jobset_changed,
    })
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
async fn lock_flake(flake: &str) -> eyre::Result<String> {
    #[derive(serde::Deserialize)]
    struct Metadata {
        url: String,
    }

    let out = crate::run_with_timeout(
        tokio::process::Command::new("nix")
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

/// Where `nix-eval-jobs` roots the evaluated derivations. The queue runner
/// uses the same directory, so `hydra-update-gc-roots` tidies it.
fn gc_roots_dir(configured: Option<&std::path::Path>) -> eyre::Result<PathBuf> {
    let dir = if let Some(dir) = configured {
        dir.to_owned()
    } else {
        let remote = daemon_client_utils::parse_nix_remote()
            .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
        let logname = std::env::var("LOGNAME").wrap_err("LOGNAME is not set")?;
        remote
            .state_dir
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots")
    };
    fs_err::create_dir_all(&dir)?;
    Ok(dir)
}

/// Whether Postgres aborted the work as a deadlock victim or for a
/// serialization failure.
fn is_conflict(e: &eyre::Report) -> bool {
    let conflict = |e: &sqlx::Error| {
        e.as_database_error()
            .and_then(sqlx::error::DatabaseError::code)
            .is_some_and(|code| code == "40P01" || code == "40001")
    };
    e.chain().any(|cause| {
        // `db::Error::Sql` is transparent, so its `sqlx::Error` is not its
        // own element of the chain.
        cause.downcast_ref::<sqlx::Error>().is_some_and(conflict)
            || matches!(cause.downcast_ref::<db::Error>(), Some(db::Error::Sql(e)) if conflict(e))
    })
}

/// Apply the derivation changes an evaluation found for builds it inherited.
///
/// Separate from the evaluation transaction for the same reason as
/// `mark_current`: these are `Builds` rows the queue runner also writes.
async fn repoint(conn: &mut db::Connection, repoints: &HashMap<i32, String>) -> eyre::Result<()> {
    let mut ids: Vec<&i32> = repoints.keys().collect();
    ids.sort_unstable();
    for id in ids {
        queries::repoint_build(conn, *id, &repoints[id]).await?;
    }
    Ok(())
}
