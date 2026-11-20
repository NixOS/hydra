//! Completing one evaluation from its finished build.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};
use futures::TryFutureExt as _;

use crate::{ingest, jobs, queries};

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// Read a finished evaluation build's output back, and turn its jobs into
/// builds of the jobset that was evaluated.
pub(crate) async fn complete(
    db: &db::Database,
    roots_dir: &std::path::Path,
    eval_id: i32,
) -> eyre::Result<()> {
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

    // What this evaluation is compared against: the jobs of the last one with
    // new builds, so a job already built is not built again, and how many
    // there were, since a job disappearing changes the jobset while queueing
    // nothing.
    let previous =
        queries::get_previous_eval_with_new_builds(&mut conn, eval.jobset_id, eval_id).await?;
    drop(conn);

    // An evaluation that cannot be recorded -- an aggregate whose constituent
    // does not exist -- is still over, so that is not an error to retry: the
    // inner result carries it out of the retry loop.
    let ingest_start = std::time::Instant::now();
    let recorded = retry("the evaluation transaction", || async {
        let mut conn = db.get().await?;
        let mut tx = conn.begin_transaction().await?;
        match ingest::record(&mut tx, &eval, eval_id, &jobs, previous).await {
            Ok(recorded) => {
                queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
                tx.commit().await?;
                Ok(Ok(recorded))
            }
            Err(e) if is_retryable(&e) => Err(e),
            Err(e) => Ok(Err(e)),
        }
    })
    .await?;

    // Nothing it queued is kept, but the error is, on the evaluation and on
    // the jobset, and it is marked completed so it is not tried again.
    let recorded = match recorded {
        Ok(recorded) => recorded,
        Err(e) => {
            let message = format!("{e:#}");
            let mut conn = db.get().await?;
            let mut tx = conn.begin_transaction().await?;
            if let Some(error_id) = eval.evaluationerror_id {
                queries::set_evaluation_error(&mut tx, error_id, &message).await?;
            }
            queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
            tx.commit().await?;
            queries::record_failure(&mut conn, trace, eval.jobset_id, &message, now()).await?;
            return Err(e.wrap_err("failed to record the evaluation"));
        }
    };
    tracing::info!(
        "recorded {} jobs in {} s",
        jobs.len(),
        ingest_start.elapsed().as_secs()
    );

    // Root every job's derivation, not only those that became builds: an
    // aggregate is reported as a job and nothing else in the store refers to
    // its derivation. `nix-eval-jobs --gc-roots-dir` did this while
    // evaluation ran on this machine; the build that runs it now cannot
    // write outside its sandbox, so the roots are made here instead.
    if let Err(e) = add_roots(roots_dir, jobs.iter().filter_map(|j| j.drv_path.as_deref())) {
        tracing::warn!("could not root the evaluated derivations: {e:#}");
    }

    // The current builds are this evaluation's if it changed anything, and
    // otherwise still those of the last one that did.
    let current = if recorded.jobset_changed {
        Some(eval_id)
    } else {
        previous.map(|p| p.id)
    };

    // Both of these touch every build of the jobset, so they run outside the
    // evaluation transaction: holding those row locks that long deadlocks
    // against the queue runner finishing builds. A failure is the jobset's
    // evaluation error; the next evaluation that is not cached repeats both.
    if let Err(e) = followup(db, eval.jobset_id, &recorded.repoints, current).await {
        let message = format!("{e:#}");
        queries::record_failure(&mut db.get().await?, trace, eval.jobset_id, &message, now())
            .await?;
        return Err(e);
    }
    Ok(())
}

async fn followup(
    db: &db::Database,
    jobset_id: i32,
    repoints: &HashMap<i32, String>,
    current: Option<i32>,
) -> eyre::Result<()> {
    let start = std::time::Instant::now();
    retry("repointing builds", || repoint(db, repoints))
        .await
        .wrap_err("failed to repoint builds at their new derivations")?;
    tracing::info!(
        "repointed {} builds in {} s",
        repoints.len(),
        start.elapsed().as_secs()
    );

    if let Some(current) = current {
        let start = std::time::Instant::now();
        retry("marking builds current", || async {
            let mut conn = db.get().await?;
            Ok(queries::mark_current(&mut conn, jobset_id, current, CURRENT_BATCH).await?)
        })
        .await
        .wrap_err("failed to mark this evaluation's builds current")?;
        tracing::info!(
            "marked evaluation {current}'s builds current in {} s",
            start.elapsed().as_secs()
        );
    }
    Ok(())
}

/// Apply the derivation changes an evaluation found for builds it inherited,
/// in one transaction and in id order.
///
/// Separate from the evaluation transaction for the same reason as
/// `mark_current`: these are `Builds` rows the queue runner also writes.
async fn repoint(db: &db::Database, repoints: &HashMap<i32, String>) -> eyre::Result<()> {
    if repoints.is_empty() {
        return Ok(());
    }
    let mut ids: Vec<&i32> = repoints.keys().collect();
    ids.sort_unstable();
    let mut conn = db.get().await?;
    let mut tx = conn.begin_transaction().await?;
    for id in ids {
        queries::repoint_build(&mut tx, *id, &repoints[id]).await?;
    }
    tx.commit().await?;
    Ok(())
}

/// [`db::retry_serialization_failures`] for work that fails with an
/// [`eyre::Report`]. Each attempt must take its own connection.
async fn retry<T, Fut>(what: &str, mut work: impl FnMut() -> Fut) -> eyre::Result<T>
where
    Fut: Future<Output = eyre::Result<T>>,
{
    db::retry_serialization_failures(what, || work().map_err(Retryable))
        .await
        .map_err(|e| e.0)
}

/// Whether a database error in the chain is a serialization failure or a
/// deadlock, after which the transaction can be run again from the top.
fn is_retryable(e: &eyre::Report) -> bool {
    use db::RetryableError as _;
    e.chain().any(|cause| {
        cause
            .downcast_ref::<db::Error>()
            .is_some_and(db::Error::is_retryable_serialization_failure)
            || cause
                .downcast_ref::<sqlx::Error>()
                .is_some_and(sqlx::Error::is_retryable_serialization_failure)
    })
}

/// An [`eyre::Report`] that is retryable when [`is_retryable`] says so.
struct Retryable(eyre::Report);

impl db::RetryableError for Retryable {
    fn is_retryable_serialization_failure(&self) -> bool {
        is_retryable(&self.0)
    }
}

impl std::fmt::Display for Retryable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#}", self.0)
    }
}

/// Symlink each derivation into Hydra's roots directory -- the same one the
/// queue runner uses, so `hydra-update-gc-roots` knows to tidy it.
fn add_roots<'a>(dir: &std::path::Path, drvs: impl Iterator<Item = &'a str>) -> eyre::Result<()> {
    for drv in drvs {
        let Some(name) = std::path::Path::new(drv).file_name() else {
            continue;
        };
        match fs_err::os::unix::fs::symlink(drv, dir.join(name)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e).wrap_err_with(|| format!("rooting {drv}")),
        }
    }
    Ok(())
}

pub(crate) fn now() -> db::Timestamp {
    jiff::Timestamp::now().as_second()
}
