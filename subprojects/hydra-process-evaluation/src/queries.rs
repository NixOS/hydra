//! Compile-time-checked queries for completing evaluations: which are
//! waiting, what their build produced, and the builds that come of it.

use sqlx::Acquire as _;

/// Evaluations whose build has finished but which have not been read back.
///
/// `completed IS NULL` is the only honest way to spot the gap: an evaluation
/// may legitimately have found no jobs.
pub(crate) async fn get_evals_awaiting_completion(
    conn: &mut db::Connection,
) -> Result<Vec<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        "SELECT e.id FROM jobsetevals e \
         JOIN builds b ON e.eval_build = b.id \
         WHERE e.completed IS NULL AND b.finished != 0 \
         ORDER BY e.id"
    )
    .fetch_all(conn.raw())
    .await?
    .into_iter()
    .map(|r| r.id)
    .collect())
}

/// The evaluations a build was performing, if it was performing any.
pub(crate) async fn get_evals_for_build(
    conn: &mut db::Connection,
    build_id: i32,
) -> Result<Vec<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        "SELECT id FROM jobsetevals WHERE eval_build = $1 AND completed IS NULL ORDER BY id",
        build_id,
    )
    .fetch_all(conn.raw())
    .await?
    .into_iter()
    .map(|r| r.id)
    .collect())
}

/// What completing an evaluation needs to know: how its build went, and the
/// jobset it belongs to.
#[derive(Debug)]
pub(crate) struct EvalToComplete {
    pub(crate) jobset_id: i32,
    pub(crate) jobset_name: String,
    pub(crate) declfile: Option<String>,
    pub(crate) errormsg: Option<String>,
    pub(crate) evaluationerror_id: Option<i32>,
    pub(crate) trace_id: Option<String>,
    pub(crate) build_status: Option<i32>,
    pub(crate) out_path: Option<String>,
}

pub(crate) async fn get_eval_to_complete(
    conn: &mut db::Connection,
    eval_id: i32,
) -> Result<Option<EvalToComplete>, sqlx::Error> {
    sqlx::query_as!(
        EvalToComplete,
        r#"
        SELECT e.jobset_id, j.name as jobset_name, p.declfile, j.errormsg,
               e.evaluationerror_id, e.trace_id,
               b.buildstatus as build_status, o.path as out_path
        FROM jobsetevals e
        JOIN jobsets j ON j.id = e.jobset_id
        JOIN projects p ON p.name = j.project
        JOIN builds b ON b.id = e.eval_build
        LEFT JOIN buildoutputs o ON o.build = b.id AND o.name = 'out'
        WHERE e.id = $1"#,
        eval_id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// The evaluation before a given one, and how many jobs it covered.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PreviousEval {
    pub(crate) id: i32,
    pub(crate) members: i64,
}

/// Excludes the evaluation itself and any not yet completed: the row exists
/// before its jobs do, so "the newest" would be this one.
pub(crate) async fn get_previous_completed_eval(
    conn: &mut db::Connection,
    jobset_id: i32,
    eval_id: i32,
) -> Result<Option<PreviousEval>, sqlx::Error> {
    sqlx::query_as!(
        PreviousEval,
        r#"
        SELECT id, (SELECT COUNT(*) FROM jobsetevalmembers WHERE eval = e.id) as "members!"
        FROM jobsetevals e
        WHERE jobset_id = $1 AND id < $2 AND completed IS NOT NULL
        ORDER BY id DESC
        LIMIT 1"#,
        jobset_id,
        eval_id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// Say that an evaluation has been read back from its build.
pub(crate) async fn mark_eval_completed(
    tx: &mut db::Transaction<'_>,
    eval_id: i32,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsetevals SET completed = $2 WHERE id = $1",
        eval_id,
        now,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Record how the evaluation went on the jobset. An empty error is a
/// success, and clears the one before.
pub(crate) async fn record_result(
    conn: &mut db::Connection,
    jobset_id: i32,
    error_msg: &str,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET errormsg = $2, fetcherrormsg = NULL, \
           errortime = CASE WHEN $2 = '' THEN NULL ELSE $3::bigint END \
         WHERE id = $1",
        jobset_id,
        error_msg,
        now,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Record that the evaluation failed, and tell listeners.
///
/// The notification carries whether the error differs from the one the
/// jobset already had, because that decides whether anyone is told about
/// it and it cannot be worked out afterwards -- by then the row holds the
/// new error. Reading the old one, writing the new one and announcing it
/// are one transaction, both so the flag cannot race and because `NOTIFY`
/// is delivered on commit.
pub(crate) async fn record_failure(
    conn: &mut db::Connection,
    trace: &str,
    jobset_id: i32,
    error_msg: &str,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    let mut tx = conn.raw().begin().await?;

    let previous = sqlx::query_scalar!(
        "SELECT errormsg FROM jobsets WHERE id = $1 FOR UPDATE",
        jobset_id,
    )
    .fetch_optional(&mut *tx)
    .await?
    .flatten()
    .unwrap_or_default();

    sqlx::query!(
        "UPDATE jobsets SET errormsg = $2, errortime = $3, fetcherrormsg = NULL WHERE id = $1",
        jobset_id,
        error_msg,
        now,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "SELECT pg_notify('eval_failed', $1)",
        format!("{trace}\t{jobset_id}\t{}", i32::from(error_msg != previous)),
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}

/// Point the jobset's `iscurrent` flags at this evaluation.
///
/// In batches, outside the evaluation transaction: on a jobset with
/// 100k builds this touches every row, and holding those locks for the
/// evaluation's duration deadlocks against the queue runner finishing
/// builds.
pub(crate) async fn mark_current(
    conn: &mut db::Connection,
    jobset_id: i32,
    eval: i32,
    batch: i32,
) -> Result<(), sqlx::Error> {
    // Loop until a batch changes nothing, which is when every row is in
    // the state this evaluation says it should be.
    loop {
        let n = sqlx::query!(
            r#"
            UPDATE builds SET iscurrent = 1 WHERE id IN (
              SELECT b.id FROM builds b
              JOIN jobsetevalmembers m ON m.build = b.id
              WHERE m.eval = $1 AND b.iscurrent = 0
              ORDER BY b.id LIMIT $2)"#,
            eval,
            i64::from(batch),
        )
        .execute(conn.raw())
        .await?
        .rows_affected();
        if n == 0 {
            break;
        }
    }

    loop {
        let n = sqlx::query!(
            r#"
            UPDATE builds SET iscurrent = 0 WHERE id IN (
              SELECT b.id FROM builds b
              WHERE b.jobset_id = $1 AND b.iscurrent = 1
                AND NOT EXISTS (
                  SELECT 1 FROM jobsetevalmembers m
                  WHERE m.eval = $2 AND m.build = b.id)
              ORDER BY b.id LIMIT $3)"#,
            jobset_id,
            eval,
            i64::from(batch),
        )
        .execute(conn.raw())
        .await?
        .rows_affected();
        if n == 0 {
            break;
        }
    }

    Ok(())
}

/// Point a build at the derivation this evaluation found for it, and put
/// it back in the queue.
pub(crate) async fn repoint_build(
    conn: &mut db::Connection,
    id: i32,
    drv_path: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE builds SET drvpath = $2, finished = 0, buildstatus = NULL WHERE id = $1",
        id,
        drv_path,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Record what the evaluation found: whether it changed anything, and
/// how many builds it covers.
pub(crate) async fn finish_eval(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    has_new_builds: bool,
    nr_builds: Option<i32>,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsetevals SET hasnewbuilds = $2, nrbuilds = $3 WHERE id = $1",
        eval,
        i32::from(has_new_builds),
        nr_builds,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// The evaluation's members, in bulk.
pub(crate) async fn insert_eval_members(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    members: &[(i32, bool)],
) -> Result<(), sqlx::Error> {
    let builds: Vec<i32> = members.iter().map(|(b, _)| *b).collect();
    let is_new: Vec<i32> = members.iter().map(|(_, n)| i32::from(*n)).collect();
    sqlx::query!(
        r#"
        INSERT INTO jobsetevalmembers (eval, build, isnew)
        SELECT $1, * FROM UNNEST($2::int[], $3::int[])"#,
        eval,
        &builds,
        &is_new,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// One aggregate's constituents. Upserted, since a constituent may be
/// named by more than one aggregate.
pub(crate) async fn insert_aggregate_constituent(
    tx: &mut db::Transaction<'_>,
    aggregate: i32,
    constituent: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        r#"
        INSERT INTO aggregateconstituents (aggregate, constituent)
        VALUES ($1, $2)
        ON CONFLICT (aggregate, constituent) DO NOTHING"#,
        aggregate,
        constituent,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Fill in what went wrong, once the whole evaluation has been seen.
pub(crate) async fn set_evaluation_error(
    tx: &mut db::Transaction<'_>,
    id: i32,
    msg: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE evaluationerrors SET errormsg = $2 WHERE id = $1",
        id,
        msg,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Tell listeners the evaluation is recorded.
pub(crate) async fn notify_eval_added(
    tx: &mut db::Transaction<'_>,
    trace: &str,
    jobset_id: i32,
    eval: i32,
    error_changed: bool,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "SELECT pg_notify('eval_added', $1)",
        format!("{trace}\t{jobset_id}\t{eval}\t{}", i32::from(error_changed)),
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// A build found in the previous evaluation of the same job.
#[derive(Debug)]
pub(crate) struct PreviousBuild {
    pub(crate) id: i32,
    pub(crate) finished: i32,
    pub(crate) drvpath: String,
}

/// A build of this job already present in the given evaluation, matched
/// on its first output's path, or on the derivation when there is no
/// path yet.
pub(crate) async fn find_build_in_eval(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    jobset_id: i32,
    job: &str,
    output_name: &str,
    output_path: Option<&str>,
    drv_path: &str,
) -> Result<Option<PreviousBuild>, sqlx::Error> {
    // The jobset constraint is implied by the evaluation, but stating it
    // is worth a factor of a thousand on the nixpkgs jobset.
    sqlx::query_as!(
        PreviousBuild,
        r#"
        SELECT b.id, b.finished, b.drvpath
        FROM jobsetevalmembers m
        JOIN builds b ON m.build = b.id
        JOIN buildoutputs o ON o.build = b.id
        WHERE m.eval = $1 AND b.jobset_id = $2 AND b.job = $3
          AND o.name = $4
          AND (($5::text IS NULL AND b.drvpath = $6) OR o.path = $5)
        LIMIT 1"#,
        eval,
        jobset_id,
        job,
        output_name,
        output_path,
        drv_path,
    )
    .fetch_optional(tx.raw())
    .await
}

/// Everything needed to queue a build. The `meta` fields are all optional,
/// because a jobset may set none of them.
#[derive(Debug)]
pub(crate) struct NewBuild<'a> {
    pub(crate) jobset_id: i32,
    pub(crate) job: &'a str,
    pub(crate) drv_path: &'a str,
    pub(crate) system: &'a str,
    pub(crate) nix_name: Option<&'a str>,
    pub(crate) description: Option<&'a str>,
    pub(crate) license: Option<String>,
    pub(crate) homepage: Option<&'a str>,
    pub(crate) maintainers: Option<String>,
    pub(crate) max_silent: Option<i32>,
    pub(crate) timeout: Option<i32>,
    pub(crate) priority: i32,
    pub(crate) is_channel: i32,
}

/// Add a build to the queue, returning its id.
pub(crate) async fn insert_build(
    tx: &mut db::Transaction<'_>,
    build: &NewBuild<'_>,
    now: db::Timestamp,
) -> Result<i32, sqlx::Error> {
    Ok(sqlx::query!(
        r#"
        INSERT INTO builds
          (timestamp, jobset_id, job, drvpath, system, nixname, description,
           license, homepage, maintainers, maxsilent, timeout, priority,
           finished, iscurrent, ischannel)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 0, 1, $14)
        RETURNING id"#,
        now,
        build.jobset_id,
        build.job,
        build.drv_path,
        build.system,
        build.nix_name,
        build.description,
        build.license,
        build.homepage,
        build.maintainers,
        build.max_silent,
        build.timeout,
        build.priority,
        build.is_channel,
    )
    .fetch_one(tx.raw())
    .await?
    .id)
}

/// Record a build's outputs. In bulk, because a row at a time dominates
/// insertion time on a large jobset.
pub(crate) async fn insert_build_outputs(
    tx: &mut db::Transaction<'_>,
    build: i32,
    outputs: &[(String, String)],
) -> Result<(), sqlx::Error> {
    let names: Vec<String> = outputs.iter().map(|(n, _)| n.clone()).collect();
    let paths: Vec<String> = outputs.iter().map(|(_, p)| p.clone()).collect();
    sqlx::query!(
        r#"
        INSERT INTO buildoutputs (build, name, path)
        SELECT $1, * FROM UNNEST($2::text[], $3::text[])"#,
        build,
        &names,
        &paths,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}
