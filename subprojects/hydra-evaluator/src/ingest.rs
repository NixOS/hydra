//! Turning the jobs an evaluation found into builds.
//!
//! This is the half of an evaluation that touches no plugins: by the time a
//! job arrives there are no inputs left to fetch, only the question of
//! whether this job is already built and, if not, queueing it. The jobs are
//! staged in the database and that question answered there; see
//! [`crate::staging`].

use std::collections::HashMap;
use std::fmt::Write as _;

use color_eyre::eyre::{self, WrapErr as _};

use crate::nix_eval_jobs::Job;
use crate::queries;
use crate::staging;

/// Check that a job which evaluated can be built, and stage it.
fn stage_job<'j>(staged: &mut staging::Jobs<'j>, ord: i32, job: &'j Job) -> eyre::Result<()> {
    let drv_path = job
        .drv_path
        .as_deref()
        .ok_or_else(|| eyre::eyre!("job `{}` has no derivation", job.attr))?;
    eyre::ensure!(!job.attr.is_empty(), "a job has no name");

    // Any one output will do for finding the job's previous build: if one
    // matches the others will too, since they come from the same derivation.
    // A content-addressed output has no path yet, and is matched by
    // derivation.
    let (first_name, first_path) = job
        .outputs
        .iter()
        .next()
        .ok_or_else(|| eyre::eyre!("job `{}` has no outputs", job.attr))?;

    staged.push(ord, job, drv_path, (first_name, first_path.as_deref()));
    Ok(())
}

/// What [`record`] wrote.
pub(crate) struct Recorded {
    pub eval: i32,
    pub jobset_changed: bool,
    /// Builds inherited from an earlier evaluation whose derivation has
    /// changed, to be pointed at the new one once this transaction is done.
    pub repoints: HashMap<i32, String>,
}

/// Everything an evaluation records, including the jobset's new error, in
/// the caller's transaction.
///
/// One transaction, because an evaluation's builds, members, aggregates and
/// the notifications announcing them must be written together or not at all.
/// The notifications are sent from here for the same reason, since `NOTIFY`
/// is delivered on commit.
pub(crate) async fn record(
    tx: &mut db::Transaction<'_>,
    trace: &str,
    eval: &queries::NewEval<'_>,
    jobs: &[Job],
    prev_eval: Option<i32>,
    inputs: &crate::inputs::InputInfo,
    store_dir: &db::StoreDir,
) -> eyre::Result<Recorded> {
    let jobset_id = eval.jobset_id;
    let error_time = jiff::Timestamp::now().as_second();
    let error_id = queries::insert_evaluation_error(tx, error_time).await?;
    let eval_id = queries::insert_eval(tx, eval, error_id).await?;

    let mut error = String::new();
    let mut staged = staging::Jobs::default();
    for (ord, job) in (0..).zip(jobs) {
        // A job that failed to evaluate is reported but not built. The
        // evaluation still happened; this is what it found.
        if let Some(message) = &job.error {
            let where_ = if job.attr.is_empty() {
                "at top-level".to_owned()
            } else {
                format!("in job ‘{}’", job.attr)
            };
            let _ = write!(error, "{where_}:\n{message}\n\n");
        } else {
            stage_job(&mut staged, ord, job)?;
        }
    }
    staging::stage(tx, &staged)
        .await
        .wrap_err("failed to stage the evaluation's jobs")?;
    drop(staged);

    // Already built, or already queued and still current for this job? Then
    // this evaluation inherits it rather than queueing another.
    //
    // Note what this means when a jobset's sources go from A to B and back to
    // A: three builds, not two. That is deliberate -- the highest build id
    // must be the one that ends up in the channel.
    if let Some(prev_eval) = prev_eval {
        staging::inherit(tx, prev_eval, jobset_id).await?;
    }
    staging::queue_new(tx, jobset_id)
        .await
        .wrap_err("failed to queue the evaluation's builds")?;
    staging::notify_builds(tx, eval_id).await?;

    // Did this evaluation change anything? Either it queued something, or the
    // set of jobs is a different size than last time -- a job disappearing is
    // a change even though it queues nothing.
    let (nr_members, queued) = staging::summary(tx).await?;
    let jobset_changed = queued
        || match prev_eval {
            Some(prev) => nr_members != queries::count_eval_members(tx, prev).await?,
            None => false,
        };

    let nr_builds = i32::try_from(nr_members).ok();
    queries::finish_eval(
        tx,
        eval_id,
        jobset_changed,
        jobset_changed.then_some(nr_builds).flatten(),
    )
    .await?;
    queries::finish_jobset_eval(tx, jobset_id).await?;
    let error_changed = queries::set_jobset_error(tx, jobset_id, &error, error_time).await?;
    tx.notify_eval_added(trace, jobset_id, eval_id, error_changed)
        .await?;

    if jobset_changed {
        staging::insert_members(tx, eval_id).await?;
        record_aggregates(tx, jobs).await?;
        // What wakes the queue runner: it polls otherwise.
        if queued {
            tx.notify_builds_added().await?;
        }

        for (name, alts) in inputs {
            for (n, alt) in alts.iter().enumerate() {
                queries::insert_eval_input(
                    tx,
                    eval_id,
                    name,
                    i32::try_from(n).unwrap_or(0),
                    alt,
                    store_dir,
                )
                .await?;
            }
        }
    }

    if !error.is_empty() {
        queries::set_evaluation_error(tx, error_id, &error).await?;
    }

    let repoints = staging::repoints(tx).await?.into_iter().collect();

    Ok(Recorded {
        eval: eval_id,
        jobset_changed,
        repoints,
    })
}

/// Link each aggregate to its constituents; see
/// [`staging::insert_aggregates`].
async fn record_aggregates(tx: &mut db::Transaction<'_>, jobs: &[Job]) -> eyre::Result<()> {
    // An aggregate that did not evaluate cannot be assembled, and silently
    // producing a partial one would be worse than failing.
    if let Some(job) = jobs
        .iter()
        .find(|j| j.constituents.is_some() && j.error.is_some())
    {
        eyre::bail!(
            "aggregate job ‘{}’ failed with the error: {}",
            job.attr,
            job.error.as_deref().unwrap_or_default()
        );
    }

    staging::insert_aggregates(tx).await?;

    if tracing::enabled!(tracing::Level::DEBUG) {
        for (aggregate, constituent) in staging::missing_constituents(tx).await? {
            tracing::debug!(
                "aggregate job ‘{aggregate}’ has a constituent ‘{constituent}’ \
                 that doesn't correspond to a Hydra build"
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::nix_eval_jobs::Job;
    use crate::queries::{self, NewEval};

    fn job(value: serde_json::Value) -> Job {
        serde_json::from_value(value).unwrap()
    }

    async fn record(conn: &mut db::Connection, jobs: &[Job], prev: Option<i32>) -> super::Recorded {
        let new_eval = NewEval {
            jobset_id: 1,
            checkout_time: 0,
            eval_time: 0,
            hash: "hash",
            flake: None,
            nix_expr_input: Some("src"),
            nix_expr_path: Some("release.nix"),
        };
        let mut tx = conn.begin_transaction().await.unwrap();
        let recorded = super::record(
            &mut tx,
            "trace",
            &new_eval,
            jobs,
            prev,
            &crate::inputs::InputInfo::new(),
            &db::StoreDir::new("/nix/store").unwrap(),
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();
        recorded
    }

    /// What the follow-up does, returning how many builds it repointed.
    async fn follow_up(
        conn: &mut db::Connection,
        recorded: &super::Recorded,
        current: i32,
    ) -> usize {
        let mut tx = conn.begin_transaction().await.unwrap();
        for (id, drv_path) in &recorded.repoints {
            queries::repoint_build(&mut tx, *id, drv_path)
                .await
                .unwrap();
        }
        tx.commit().await.unwrap();
        queries::mark_current(conn, 1, current, 2).await.unwrap();
        recorded.repoints.len()
    }

    /// `(id, job, drvpath, finished, iscurrent)` of every build.
    async fn builds(pool: &sqlx::PgPool) -> Vec<(i32, String, String, i32, i32)> {
        sqlx::query_as("SELECT id, job, drvpath, finished, iscurrent FROM builds ORDER BY id")
            .fetch_all(pool)
            .await
            .unwrap()
    }

    /// Two evaluations of one jobset: the first queues everything, the
    /// second inherits what it can, repoints a changed derivation, queues a
    /// new job, and drops one. A third changes nothing.
    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn record_inherits_queues_and_repoints() {
        let (pg, pool) = test_utils::TestPg::new().await;
        sqlx::raw_sql(
            "INSERT INTO users (username, emailaddress, password) VALUES ('u', '', '');
             INSERT INTO projects (name, displayname, owner) VALUES ('p', 'p', 'u');
             INSERT INTO jobsets (name, project, emailoverride, nixexprinput, nixexprpath)
             VALUES ('j', 'p', '', 'src', 'release.nix');",
        )
        .execute(&pool)
        .await
        .unwrap();
        let db = db::Database::new(&pg.url(), 1).await.unwrap();
        let mut conn = db.get().await.unwrap();

        let first = [
            job(serde_json::json!({
                "attr": "a", "drvPath": "/nix/store/a1.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/a1"},
            })),
            job(serde_json::json!({
                "attr": "b", "drvPath": "/nix/store/b1.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/b1"},
            })),
            // Content-addressed, so matched by derivation next time.
            job(serde_json::json!({
                "attr": "ca", "drvPath": "/nix/store/ca.drv", "system": "x86_64-linux",
                "outputs": {"out": null},
            })),
            job(serde_json::json!({
                "attr": "agg", "drvPath": "/nix/store/agg.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/agg"},
                "constituents": ["/nix/store/a1.drv", "/nix/store/b1.drv", "/nix/store/x.drv"],
            })),
            job(serde_json::json!({"attr": "broken", "error": "oops"})),
        ];
        let one = record(&mut conn, &first, None).await;
        assert!(one.jobset_changed);
        assert_eq!(follow_up(&mut conn, &one, one.eval).await, 0);

        assert_eq!(
            builds(&pool).await,
            [
                (1, "a".into(), "/nix/store/a1.drv".into(), 0, 1),
                (2, "b".into(), "/nix/store/b1.drv".into(), 0, 1),
                (3, "ca".into(), "/nix/store/ca.drv".into(), 0, 1),
                (4, "agg".into(), "/nix/store/agg.drv".into(), 0, 1),
            ]
        );
        let constituents: Vec<(i32, i32)> =
            sqlx::query_as("SELECT aggregate, constituent FROM aggregateconstituents ORDER BY 2")
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(constituents, [(4, 1), (4, 2)]);
        let error: String = sqlx::query_scalar(
            "SELECT e.errormsg FROM jobsetevals v
             JOIN evaluationerrors e ON e.id = v.evaluationerror_id WHERE v.id = $1",
        )
        .bind(one.eval)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(error, "in job ‘broken’:\noops\n\n");

        sqlx::query("UPDATE builds SET finished = 1, buildstatus = 0, starttime = 1, stoptime = 1 WHERE id = 2")
            .execute(&pool)
            .await
            .unwrap();

        let second = [
            job(serde_json::json!({
                "attr": "a", "drvPath": "/nix/store/a1.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/a1"},
            })),
            // Same output from a different derivation: inherited, then
            // repointed and queued again.
            job(serde_json::json!({
                "attr": "b", "drvPath": "/nix/store/b2.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/b1"},
            })),
            job(serde_json::json!({
                "attr": "ca", "drvPath": "/nix/store/ca.drv", "system": "x86_64-linux",
                "outputs": {"out": null},
            })),
            job(serde_json::json!({
                "attr": "c", "drvPath": "/nix/store/c1.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/c1"},
            })),
        ];
        let two = record(&mut conn, &second, Some(one.eval)).await;
        assert!(two.jobset_changed);
        assert_eq!(follow_up(&mut conn, &two, two.eval).await, 1);

        assert_eq!(
            builds(&pool).await,
            [
                (1, "a".into(), "/nix/store/a1.drv".into(), 0, 1),
                (2, "b".into(), "/nix/store/b2.drv".into(), 0, 1),
                (3, "ca".into(), "/nix/store/ca.drv".into(), 0, 1),
                (4, "agg".into(), "/nix/store/agg.drv".into(), 0, 0),
                (5, "c".into(), "/nix/store/c1.drv".into(), 0, 1),
            ]
        );
        let members: Vec<(i32, i32)> = sqlx::query_as(
            "SELECT build, isnew FROM jobsetevalmembers WHERE eval = $1 ORDER BY build",
        )
        .bind(two.eval)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(members, [(1, 0), (2, 0), (3, 0), (5, 1)]);
        let outputs: Vec<(String, Option<String>)> =
            sqlx::query_as("SELECT name, path FROM buildoutputs WHERE build = 5")
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(
            outputs,
            [("out".to_owned(), Some("/nix/store/c1".to_owned()))]
        );

        // An evaluation that changes nothing records no members, and has
        // nothing to repoint.
        let three = record(&mut conn, &second, Some(two.eval)).await;
        assert!(!three.jobset_changed);
        assert_eq!(follow_up(&mut conn, &three, two.eval).await, 0);
    }
}
