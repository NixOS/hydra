//! Completing one evaluation from its finished build.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};

use crate::{ingest, jobs, queries};

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// Read a finished evaluation build's output back, and turn its jobs into
/// builds of the jobset that was evaluated.
pub(crate) async fn complete(db: &db::Database, eval_id: i32) -> eyre::Result<()> {
    let mut conn = db.get().await?;
    let Some(eval) = queries::get_eval_to_complete(&mut conn, eval_id).await? else {
        return Ok(());
    };
    let trace = eval.trace_id.as_deref().unwrap_or_default();

    // A build that failed evaluated nothing; the error is the build's, and its
    // log is where it is explained.
    if eval.build_status.unwrap_or(1) != 0 {
        let mut tx = conn.begin_transaction().await?;
        queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
        tx.commit().await?;
        queries::record_failure(
            &mut conn,
            trace,
            eval.jobset_id,
            "evaluation failed; see the evaluation build's log",
            now(),
        )
        .await?;
        eyre::bail!("evaluation build failed; see its log");
    }

    let Some(path) = eval.out_path.as_deref() else {
        eyre::bail!("evaluation build {eval_id} produced no output");
    };
    let jobs = jobs::read(path)?;

    // What this evaluation is compared against: the jobs of the evaluation
    // before it, so a job already built is not built again, and how many
    // there were, since a job disappearing changes the jobset while queueing
    // nothing.
    let previous = queries::get_previous_completed_eval(&mut conn, eval.jobset_id, eval_id).await?;

    let mut tx = conn.begin_transaction().await?;
    let recorded = ingest::record(&mut tx, &eval, eval_id, &jobs, previous).await;

    // An evaluation that cannot be recorded -- an aggregate whose
    // constituent does not exist -- is still over. Nothing it queued is
    // kept, but the error is, on the evaluation and on the jobset, and it
    // is marked completed so it is not tried again.
    let recorded = match recorded {
        Ok(recorded) => recorded,
        Err(e) => {
            drop(tx);
            let message = format!("{e:#}");
            let mut tx = conn.begin_transaction().await?;
            if let Some(error_id) = eval.evaluationerror_id {
                queries::set_evaluation_error(&mut tx, error_id, &message).await?;
            }
            queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
            tx.commit().await?;
            queries::record_failure(&mut conn, trace, eval.jobset_id, &message, now()).await?;
            return Err(e);
        }
    };
    queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
    tx.commit().await?;

    // Both of these touch every build of the jobset, so they run afterwards:
    // holding those row locks for the evaluation's duration deadlocks against
    // the queue runner finishing builds.
    if recorded.jobset_changed {
        queries::mark_current(&mut conn, eval.jobset_id, eval_id, CURRENT_BATCH)
            .await
            .wrap_err("failed to mark this evaluation's builds current")?;
    }
    repoint(&mut conn, &recorded.repoints)
        .await
        .wrap_err("failed to repoint builds at their new derivations")?;

    queries::record_result(&mut conn, eval.jobset_id, &recorded.error, now()).await?;
    Ok(())
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

pub(crate) fn now() -> db::Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}
