//! Evaluating one jobset, end to end.
//!
//! Fetch the inputs, decide whether they have been evaluated before, run
//! `nix-eval-jobs` over them, and record what it found. The pieces live in
//! their own modules; this is the order they happen in and the decisions
//! between them.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};
use sha2::{Digest as _, Sha256};

use crate::config::HydraConfig;
use crate::fetcher::InputFetcher;
use crate::ingest;
use crate::inputs::{self, ConfiguredInput};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries;
use crate::queries::NewEval;

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// What evaluating a jobset produced.
#[derive(Debug)]
pub(crate) enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// The evaluation ran and was recorded.
    Evaluated { eval: i32, changed: bool },
}

pub(crate) async fn evaluate(
    db: &db::Database,
    config: &HydraConfig,
    available: &crate::store_paths::Availability,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let mut conn = db.get().await?;
    let meta = queries::get_jobset_for_eval(&mut conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;

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
        .collect();

    let mut fetcher = InputFetcher::start()?;
    let resolved = inputs::resolve(
        &mut conn,
        &mut fetcher,
        available,
        project,
        jobset,
        &configured,
    )
    .await;
    fetcher.shutdown().await;
    let resolved = resolved?;
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
    let hash = format!("{:x}", Sha256::digest(cmd.join(" ").as_bytes()));
    let previous = queries::get_previous_eval(&mut conn, meta.id).await?;

    if let Some(previous) = &previous {
        if previous.hash == hash
            && !meta.forceeval.unwrap_or(false)
            && meta.flake.as_deref() == previous.flake.as_deref()
        {
            tracing::info!("({project}:{jobset}) already evaluated these inputs");
            queries::notify_eval_cached(&mut conn, trace, meta.id, previous.id).await?;
            queries::update_jobset_after_eval(&mut conn, meta.id, None, now()).await?;
            return Ok(Outcome::Cached {
                previous: previous.id,
            });
        }
    }

    tracing::info!("({project}:{jobset}) evaluating");
    let eval_start = std::time::Instant::now();
    let jobs = nix_eval_jobs::run(&cmd).await?;
    let eval_time = eval_start.elapsed().as_secs();

    // `.jobsets` is Hydra evaluating its own configuration, and is allowed
    // exactly one job.
    let jobsets_jobset =
        meta.declfile.as_deref().is_some_and(|f| !f.is_empty()) && jobset == ".jobsets";

    let prev_member_count = match &previous {
        Some(p) => Some(queries::count_eval_members(&mut conn, p.id).await?),
        None => None,
    };

    let mut tx = conn.begin_transaction().await?;
    let error_id = queries::insert_evaluation_error(&mut tx, now()).await?;
    let recorded = ingest::record(
        &mut tx,
        meta.id,
        trace,
        &NewEval {
            jobset_id: meta.id,
            checkout_time: i32::try_from(checkout_time).unwrap_or(0),
            eval_time: i32::try_from(eval_time).unwrap_or(0),
            hash: &hash,
            flake: meta.flake.as_deref(),
            nix_expr_input: meta.nixexprinput.as_deref(),
            nix_expr_path: meta.nixexprpath.as_deref(),
            evaluation_error_id: Some(error_id),
        },
        error_id,
        meta.errormsg.as_deref().unwrap_or_default(),
        &jobs,
        previous.as_ref().map(|p| p.id),
        prev_member_count,
        &resolved,
        jobsets_jobset,
    )
    .await
    .wrap_err("failed to record the evaluation")?;
    tx.commit().await?;

    // Both of these touch every build of the jobset, so they run afterwards:
    // holding those row locks for the evaluation's duration deadlocks against
    // the queue runner finishing builds.
    if recorded.jobset_changed {
        queries::mark_current(&mut conn, meta.id, recorded.eval, CURRENT_BATCH)
            .await
            .wrap_err("failed to mark this evaluation's builds current")?;
    }

    repoint(&mut conn, &recorded.repoints)
        .await
        .wrap_err("failed to repoint builds at their new derivations")?;

    queries::update_jobset_after_eval(&mut conn, meta.id, non_empty(&recorded.error), now())
        .await?;

    Ok(Outcome::Evaluated {
        eval: recorded.eval,
        changed: recorded.jobset_changed,
    })
}

fn non_empty(s: &str) -> Option<&str> {
    (!s.is_empty()).then_some(s)
}

fn now() -> db::Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
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
