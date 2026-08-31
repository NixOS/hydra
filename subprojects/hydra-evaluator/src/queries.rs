//! Compile-time-checked queries over the jobset-scheduling slice of the
//! schema, as an extension trait on [`db::Connection`]. These live here
//! rather than in the shared `db` crate because this part of the schema
//! is only relevant to the evaluator; the `db` crate provides the pooled
//! connection (with its acquire-retry) via [`db::Database::get`].

use sqlx::Acquire as _;

/// Scheduling-relevant view of an enabled jobset, as the evaluator's
/// scheduler sees it.
#[derive(Debug)]
pub(crate) struct JobsetSchedulingInfo {
    pub id: i32,
    pub project: String,
    pub name: String,
    pub lastcheckedtime: Option<db::Timestamp>,
    pub triggertime: Option<db::Timestamp>,
    pub checkinterval: i32,
    /// Raw `enabled` column: 1 = enabled, 2 = one-shot, 3 = one-at-a-time.
    pub enabled: i32,
}

/// A jobset input as configured, before it is resolved.
#[derive(Debug)]
pub(crate) struct ConfiguredInputRow {
    pub name: String,
    pub r#type: String,
    pub value: Option<String>,
    pub emailresponsible: i32,
}

/// What a `build`, `sysbuild` or `eval` input needs to know about a build.
#[derive(Debug)]
pub(crate) struct InputBuild {
    pub id: i32,
    pub releasename: Option<String>,
    pub nixname: Option<String>,
    pub out_path: Option<String>,
    pub out_name: Option<String>,
}

/// All enabled jobsets of enabled projects.
pub(crate) async fn get_schedulable_jobsets(
    conn: &mut db::Connection,
) -> Result<Vec<JobsetSchedulingInfo>, sqlx::Error> {
    sqlx::query_as!(
        JobsetSchedulingInfo,
        r#"
        SELECT
          j.id,
          j.project,
          j.name,
          lastCheckedTime,
          triggerTime,
          checkInterval,
          j.enabled
        FROM jobsets j
        JOIN projects p ON j.project = p.name
        WHERE j.enabled != 0 AND p.enabled != 0"#
    )
    .fetch_all(conn.raw())
    .await
}

/// The most recent evaluation of a jobset, if any.
pub(crate) async fn get_latest_eval_id(
    conn: &mut db::Connection,
    jobset_id: i32,
) -> Result<Option<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        "SELECT id FROM jobsetevals WHERE jobset_id = $1 ORDER BY id DESC LIMIT 1",
        jobset_id,
    )
    .fetch_optional(conn.raw())
    .await?
    .map(|v| v.id))
}

/// Whether an evaluation still has unfinished builds.
pub(crate) async fn eval_has_unfinished_builds(
    conn: &mut db::Connection,
    eval_id: i32,
) -> Result<bool, sqlx::Error> {
    Ok(sqlx::query!(
        "SELECT b.id FROM builds b \
         JOIN jobsetevalmembers m ON m.build = b.id \
         WHERE m.eval = $1 AND b.finished = 0 \
         LIMIT 1",
        eval_id,
    )
    .fetch_optional(conn.raw())
    .await?
    .is_some())
}

/// A jobset's configured inputs, with their alternatives, in the order
/// the evaluator should resolve them.
pub(crate) async fn get_jobset_inputs(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
) -> Result<Vec<ConfiguredInputRow>, sqlx::Error> {
    sqlx::query_as!(
        ConfiguredInputRow,
        r#"
        SELECT i.name, i.type, a.value, i.emailresponsible
        FROM jobsetinputs i
        LEFT JOIN jobsetinputalts a
          ON a.project = i.project AND a.jobset = i.jobset AND a.input = i.name
        WHERE i.project = $1 AND i.jobset = $2
        ORDER BY i.name, a.altnr"#,
        project,
        jobset,
    )
    .fetch_all(conn.raw())
    .await
}

/// A finished, successful build by id, for a `build` input given a number.
pub(crate) async fn get_build_for_input_by_id(
    conn: &mut db::Connection,
    id: i32,
) -> Result<Option<InputBuild>, sqlx::Error> {
    sqlx::query_as!(
        InputBuild,
        r#"
        SELECT b.id, b.releasename, b.nixname,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        LEFT JOIN buildoutputs o ON o.build = b.id AND o.name = 'out'
        WHERE b.id = $1"#,
        id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// The most recent successful build of a job, for a `build` input given
/// a job name.
pub(crate) async fn get_latest_succeeded_build(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
    job: &str,
) -> Result<Option<InputBuild>, sqlx::Error> {
    sqlx::query_as!(
        InputBuild,
        r#"
        SELECT b.id, b.releasename, b.nixname,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        JOIN jobsets j ON b.jobset_id = j.id
        LEFT JOIN buildoutputs o ON o.build = b.id AND o.name = 'out'
        WHERE j.project = $1 AND j.name = $2 AND b.job = $3
          AND b.finished = 1 AND b.buildstatus = 0
        ORDER BY b.id DESC
        LIMIT 1"#,
        project,
        jobset,
        job,
    )
    .fetch_optional(conn.raw())
    .await
}

/// The most recent successful build of a job for each system, which is
/// what a `sysbuild` input is.
pub(crate) async fn get_latest_succeeded_build_per_system(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
    job: &str,
) -> Result<Vec<InputBuild>, sqlx::Error> {
    // One per system, most recent first: that is what makes this a
    // `sysbuild` rather than a `build`.
    sqlx::query_as!(
        InputBuild,
        r#"
        SELECT DISTINCT ON (b.system)
               b.id, b.releasename, b.nixname,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        JOIN jobsets j ON b.jobset_id = j.id
        LEFT JOIN buildoutputs o ON o.build = b.id AND o.name = 'out'
        WHERE j.project = $1 AND j.name = $2 AND b.job = $3
          AND b.finished = 1 AND b.buildstatus = 0
        ORDER BY b.system, b.id DESC"#,
        project,
        jobset,
        job,
    )
    .fetch_all(conn.raw())
    .await
}

/// The evaluation an `eval` input names, by id.
pub(crate) async fn get_eval_by_id(
    conn: &mut db::Connection,
    id: i32,
) -> Result<Option<i32>, sqlx::Error> {
    Ok(sqlx::query!("SELECT id FROM jobsetevals WHERE id = $1", id)
        .fetch_optional(conn.raw())
        .await?
        .map(|r| r.id))
}

/// The most recent evaluation of a jobset all of whose builds have
/// finished -- what an `eval` input means by `project:jobset`.
pub(crate) async fn get_latest_finished_eval(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
) -> Result<Option<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        r#"
        SELECT e.id FROM jobsetevals e
        JOIN jobsets j ON e.jobset_id = j.id
        WHERE j.project = $1 AND j.name = $2 AND e.hasnewbuilds = 1
          AND NOT EXISTS (
            SELECT 1 FROM jobsetevalmembers m JOIN builds b ON m.build = b.id
            WHERE m.eval = e.id AND b.finished = 0)
        ORDER BY e.id DESC
        LIMIT 1"#,
        project,
        jobset,
    )
    .fetch_optional(conn.raw())
    .await?
    .map(|r| r.id))
}

/// As above, but only an evaluation in which the named job succeeded.
pub(crate) async fn get_latest_finished_eval_with_job(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
    job: &str,
) -> Result<Option<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        r#"
        SELECT e.id FROM jobsetevals e
        JOIN jobsets j ON e.jobset_id = j.id
        WHERE j.project = $1 AND j.name = $2 AND e.hasnewbuilds = 1
          AND NOT EXISTS (
            SELECT 1 FROM jobsetevalmembers m JOIN builds b ON m.build = b.id
            WHERE m.eval = e.id AND b.finished = 0)
          AND EXISTS (
            SELECT 1 FROM jobsetevalmembers m JOIN builds b ON m.build = b.id
            WHERE m.eval = e.id AND b.job = $3 AND b.buildstatus = 0)
        ORDER BY e.id DESC
        LIMIT 1"#,
        project,
        jobset,
        job,
    )
    .fetch_optional(conn.raw())
    .await?
    .map(|r| r.id))
}

/// The successful jobs of an evaluation, as job name to output path.
pub(crate) async fn get_eval_jobs(
    conn: &mut db::Connection,
    eval: i32,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    Ok(sqlx::query!(
        r#"
        SELECT b.job, o.path as "path!"
        FROM jobsetevalmembers m
        JOIN builds b ON m.build = b.id
        JOIN buildoutputs o ON o.build = b.id AND o.name = 'out'
        WHERE m.eval = $1 AND b.finished = 1 AND b.buildstatus = 0
          AND o.path IS NOT NULL"#,
        eval,
    )
    .fetch_all(conn.raw())
    .await?
    .into_iter()
    .map(|r| (r.job, r.path))
    .collect())
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
        r#"
        UPDATE builds
        SET drvpath = $2, finished = 0, buildstatus = NULL
        WHERE id = $1"#,
        id,
        drv_path,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// What a jobset says to evaluate, and how it was evaluated last time.
pub(crate) async fn get_jobset_for_eval(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
) -> Result<Option<JobsetForEval>, sqlx::Error> {
    sqlx::query_as!(
        JobsetForEval,
        r#"
        SELECT j.id, j.flake, j.nixexprinput, j.nixexprpath, j.forceeval,
               p.declfile, j.errormsg
        FROM jobsets j
        JOIN projects p ON j.project = p.name
        WHERE j.project = $1 AND j.name = $2"#,
        project,
        jobset,
    )
    .fetch_optional(conn.raw())
    .await
}

/// The jobset's most recent evaluation, whose hash says whether these
/// inputs have been evaluated before.
pub(crate) async fn get_previous_eval(
    conn: &mut db::Connection,
    jobset_id: i32,
) -> Result<Option<PreviousEval>, sqlx::Error> {
    sqlx::query_as!(
        PreviousEval,
        r#"
        SELECT id, hash, flake FROM jobsetevals
        WHERE jobset_id = $1
        ORDER BY id DESC
        LIMIT 1"#,
        jobset_id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// How many jobs the previous evaluation covered.
pub(crate) async fn count_eval_members(
    conn: &mut db::Connection,
    eval: i32,
) -> Result<i64, sqlx::Error> {
    Ok(sqlx::query!(
        r#"SELECT COUNT(*) as "n!" FROM jobsetevalmembers WHERE eval = $1"#,
        eval,
    )
    .fetch_one(conn.raw())
    .await?
    .n)
}

/// Tell listeners this evaluation was skipped as unchanged.
pub(crate) async fn notify_eval_cached(
    conn: &mut db::Connection,
    trace: &str,
    jobset_id: i32,
    previous: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "SELECT pg_notify('eval_cached', $1)",
        format!("{trace}\t{jobset_id}\t{previous}"),
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Mark a jobset as currently evaluating.
pub(crate) async fn set_jobset_start_time(
    conn: &mut db::Connection,
    jobset_id: i32,
    start_time: db::Timestamp,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET startTime = $1 WHERE id = $2",
        start_time,
        jobset_id,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Clear `startTime` on all jobsets, e.g. after an unclean evaluator
/// shutdown left some marked as evaluating.
pub(crate) async fn unlock_all_jobsets(conn: &mut db::Connection) -> Result<(), sqlx::Error> {
    sqlx::query!("UPDATE jobsets SET startTime = null")
        .execute(conn.raw())
        .await?;
    Ok(())
}

/// Record the outcome of an evaluation attempt: clear `triggerTime`
/// and `startTime`, and record the error on failure.
///
/// Runs in a transaction so that a partial failure cannot clear
/// `triggerTime` but leave `startTime` set, which would make the
/// jobset appear permanently running.
pub(crate) async fn update_jobset_after_eval(
    conn: &mut db::Connection,
    jobset_id: i32,
    error_msg: Option<&str>,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    let mut tx = conn.raw().begin().await?;

    // Clear trigger time to prevent a stuck eval loop
    sqlx::query!(
        "UPDATE jobsets SET triggerTime = null \
         WHERE id = $1 AND startTime IS NOT NULL AND triggerTime <= startTime",
        jobset_id,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "UPDATE jobsets SET startTime = null WHERE id = $1",
        jobset_id,
    )
    .execute(&mut *tx)
    .await?;

    if let Some(error_msg) = error_msg {
        sqlx::query!(
            "UPDATE jobsets SET errorMsg = $1, lastCheckedTime = $2, \
             errorTime = $2, fetchErrorMsg = null WHERE id = $3",
            error_msg,
            now,
            jobset_id,
        )
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

/// Record that an evaluation failed, and tell listeners.
///
/// The notification carries whether the error differs from the one the
/// jobset already had, because that decides whether anyone is told about
/// it and it cannot be worked out afterwards -- by then the row holds the
/// new error. Reading the old one, writing the new one and announcing it
/// are one transaction, both so the flag cannot race another evaluation
/// and because `NOTIFY` is delivered on commit.
pub(crate) async fn fail_jobset_eval(
    conn: &mut db::Connection,
    trace: &str,
    jobset_id: i32,
    error_msg: &str,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    let mut tx = conn.raw().begin().await?;

    let previous = sqlx::query_scalar!(
        "SELECT errorMsg FROM jobsets WHERE id = $1 FOR UPDATE",
        jobset_id,
    )
    .fetch_optional(&mut *tx)
    .await?
    .flatten()
    .unwrap_or_default();

    sqlx::query!(
        "UPDATE jobsets SET triggerTime = null \
         WHERE id = $1 AND startTime IS NOT NULL AND triggerTime <= startTime",
        jobset_id,
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "UPDATE jobsets SET startTime = null, errorMsg = $1, lastCheckedTime = $2, \
         errorTime = $2, fetchErrorMsg = null WHERE id = $3",
        error_msg,
        now,
        jobset_id,
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

/// What a jobset says to evaluate.
#[derive(Debug)]
pub(crate) struct JobsetForEval {
    pub id: i32,
    pub flake: Option<String>,
    pub nixexprinput: Option<String>,
    pub nixexprpath: Option<String>,
    pub forceeval: Option<bool>,
    pub declfile: Option<String>,
    /// The error the jobset already has, so that an evaluation can say
    /// whether the one it ends up with is different.
    pub errormsg: Option<String>,
}

/// The previous evaluation, for deciding whether to evaluate again.
#[derive(Debug)]
pub(crate) struct PreviousEval {
    pub id: i32,
    pub hash: String,
    pub flake: Option<String>,
}

/// A build found in the previous evaluation of the same job.
#[derive(Debug)]
pub(crate) struct PreviousBuild {
    pub id: i32,
    pub finished: i32,
    pub drvpath: String,
}

/// Everything needed to queue a build. The `meta` fields are all optional,
/// because a jobset may set none of them.
#[derive(Debug)]
pub(crate) struct NewBuild<'a> {
    pub jobset_id: i32,
    pub job: &'a str,
    pub drv_path: &'a str,
    pub system: &'a str,
    pub nix_name: Option<&'a str>,
    pub description: Option<&'a str>,
    pub license: Option<String>,
    pub homepage: Option<&'a str>,
    pub maintainers: Option<String>,
    pub max_silent: Option<i32>,
    pub timeout: Option<i32>,
    pub priority: i32,
    pub is_channel: i32,
}

/// The evaluation row, as it is first written: what was evaluated and with
/// what, before anything is known about the result.
#[derive(Debug)]
pub(crate) struct NewEval<'a> {
    pub jobset_id: i32,
    pub checkout_time: i32,
    pub eval_time: i32,
    pub hash: &'a str,
    pub flake: Option<&'a str>,
    pub nix_expr_input: Option<&'a str>,
    pub nix_expr_path: Option<&'a str>,
    pub evaluation_error_id: Option<i32>,
}

/// The writes an evaluation makes, which happen inside its transaction.
///
/// Separate from [`JobsetQueries`] because these are transactional: an
/// evaluation's builds and the notifications announcing them must appear
/// together or not at all, and `NOTIFY` is delivered on commit.
/// Record the evaluation itself, returning its id.
pub(crate) async fn insert_eval(
    tx: &mut db::Transaction<'_>,
    eval: &NewEval<'_>,
) -> Result<i32, sqlx::Error> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));

    Ok(sqlx::query!(
        r#"
        INSERT INTO jobsetevals
          (jobset_id, timestamp, checkouttime, evaltime, hasnewbuilds,
           nrbuilds, hash, flake, nixexprinput, nixexprpath,
           evaluationerror_id)
        VALUES ($1, $2, $3, $4, 0, 0, $5, $6, $7, $8, $9)
        RETURNING id"#,
        eval.jobset_id,
        now,
        eval.checkout_time,
        eval.eval_time,
        eval.hash,
        eval.flake,
        eval.nix_expr_input,
        eval.nix_expr_path,
        eval.evaluation_error_id,
    )
    .fetch_one(tx.raw())
    .await?
    .id)
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

/// The inputs this evaluation was performed with, recorded so that the
/// evaluation remains reproducible after they move on.
pub(crate) async fn insert_eval_input(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    name: &str,
    alt_nr: i32,
    input: &crate::inputs::JobsetInput,
) -> Result<(), sqlx::Error> {
    let short_rev_length = input
        .short_rev
        .as_ref()
        .and_then(|r| i16::try_from(r.len()).ok());
    sqlx::query!(
        r#"
        INSERT INTO jobsetevalinputs
          (eval, name, altnr, type, uri, revision, shortrevlength, value,
           dependency, path, sha256hash)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)"#,
        eval,
        name,
        alt_nr,
        input.r#type.as_deref().unwrap_or(""),
        input.uri,
        input.revision,
        short_rev_length,
        input.value,
        input.id,
        // A not-yet-fetched input has no path; the column is nullable but
        // the Perl wrote the empty string, so that is preserved.
        input.store_path.clone().unwrap_or_default(),
        input.sha256hash,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Start an error record for the evaluation, returning its id.
pub(crate) async fn insert_evaluation_error(
    tx: &mut db::Transaction<'_>,
    time: i64,
) -> Result<i32, sqlx::Error> {
    Ok(sqlx::query!(
        "INSERT INTO evaluationerrors (errormsg, errortime) VALUES ('', $1) RETURNING id",
        time,
    )
    .fetch_one(tx.raw())
    .await?
    .id)
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

/// Add a build to the queue, returning its id.
pub(crate) async fn insert_build(
    tx: &mut db::Transaction<'_>,
    build: &NewBuild<'_>,
) -> Result<i32, sqlx::Error> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));

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
