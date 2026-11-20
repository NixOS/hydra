//! Compile-time-checked queries over the parts of the schema that only the
//! evaluator uses, which is why they live here and not in the shared `db`
//! crate. The `db` crate provides the pooled connection, with its
//! acquire-retry, via [`db::Database::get`].

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
    pub drvpath: String,
    /// The main output, which is `out` or else the first output by name, as
    /// the Perl's `getMainOutput` chose.
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
        SELECT b.id, b.releasename, b.nixname, b.drvpath,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        LEFT JOIN LATERAL (
          SELECT path, name FROM buildoutputs WHERE build = b.id
          ORDER BY name <> 'out', name LIMIT 1) o ON true
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
        SELECT b.id, b.releasename, b.nixname, b.drvpath,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        JOIN jobsets j ON b.jobset_id = j.id
        LEFT JOIN LATERAL (
          SELECT path, name FROM buildoutputs WHERE build = b.id
          ORDER BY name <> 'out', name LIMIT 1) o ON true
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
               b.id, b.releasename, b.nixname, b.drvpath,
               o.path as "out_path?", o.name as "out_name?"
        FROM builds b
        JOIN jobsets j ON b.jobset_id = j.id
        LEFT JOIN LATERAL (
          SELECT path, name FROM buildoutputs WHERE build = b.id
          ORDER BY name <> 'out', name LIMIT 1) o ON true
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

/// The most recent evaluation of a jobset all of whose builds have finished,
/// which is what an `eval` input means by `project:jobset`. Given a job, only
/// an evaluation in which that job succeeded.
pub(crate) async fn get_latest_finished_eval(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
    job: Option<&str>,
) -> Result<Option<i32>, sqlx::Error> {
    Ok(sqlx::query!(
        r#"
        SELECT e.id FROM jobsetevals e
        JOIN jobsets j ON e.jobset_id = j.id
        WHERE j.project = $1 AND j.name = $2 AND e.hasnewbuilds = 1
          AND NOT EXISTS (
            SELECT 1 FROM jobsetevalmembers m JOIN builds b ON m.build = b.id
            WHERE m.eval = e.id AND b.finished = 0)
          AND ($3::text IS NULL OR EXISTS (
            SELECT 1 FROM jobsetevalmembers m JOIN builds b ON m.build = b.id
            WHERE m.eval = e.id AND b.job = $3 AND b.buildstatus = 0))
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
///
/// The rows to change are found once, into a temporary table, and each
/// batch takes the next ids from it. Finding them is a scan of the jobset's
/// builds, which on a large jobset would otherwise be repeated per batch.
/// Each batch commits on its own, so the rows are found before any of them
/// change. Nothing else changes which rows qualify: a jobset has one
/// evaluation recorded or followed up at a time, and the only other writer,
/// `insert_unevaluated_build`, queues builds with `iscurrent = 0` that
/// belong to no evaluation.
///
/// The temporary table is scratch, private to this call: nothing durable
/// depends on it. If this is interrupted, the batches already committed
/// leave some flags set as this evaluation says and the rest as before. That
/// is stale, not inconsistent, and any later call for the jobset finishes the
/// job, since it finds the rows to change afresh.
pub(crate) async fn mark_current(
    conn: &mut db::Connection,
    jobset_id: i32,
    eval: i32,
    batch: i32,
) -> Result<(), sqlx::Error> {
    // Unchecked from here on, because the checked macros cannot see a
    // temporary table: <https://github.com/launchbadge/sqlx/issues/3661>.
    // Once that is resolved, these can go back to `query!`. Dropped first in
    // case a connection returned to the pool still has one from an
    // interrupted run.
    sqlx::raw_sql(
        "DROP TABLE IF EXISTS pg_temp.currentchanges;
         CREATE TEMP TABLE currentchanges
           (id integer PRIMARY KEY, iscurrent integer NOT NULL);",
    )
    .execute(conn.raw())
    .await?;

    let to_set = sqlx::query(
        "INSERT INTO currentchanges
         SELECT b.id, 1 FROM builds b
         JOIN jobsetevalmembers m ON m.build = b.id
         WHERE m.eval = $1 AND b.iscurrent = 0",
    )
    .bind(eval)
    .execute(conn.raw())
    .await?
    .rows_affected();
    let to_clear = sqlx::query(
        "INSERT INTO currentchanges
         SELECT b.id, 0 FROM builds b
         WHERE b.jobset_id = $1 AND b.iscurrent = 1
           AND NOT EXISTS (
             SELECT 1 FROM jobsetevalmembers m
             WHERE m.eval = $2 AND m.build = b.id)",
    )
    .bind(jobset_id)
    .bind(eval)
    .execute(conn.raw())
    .await?
    .rows_affected();

    // Counted rather than looping until an update changes nothing, since a
    // build deleted meanwhile empties a batch without finishing the table.
    let batches = (to_set + to_clear).div_ceil(u64::try_from(batch).unwrap_or(1).max(1));
    for _ in 0..batches {
        sqlx::query(
            "WITH next AS (
               DELETE FROM currentchanges WHERE id IN (
                 SELECT id FROM currentchanges ORDER BY id LIMIT $1)
               RETURNING id, iscurrent)
             UPDATE builds SET iscurrent = next.iscurrent
             FROM next WHERE builds.id = next.id",
        )
        .bind(i64::from(batch))
        .execute(conn.raw())
        .await?;
    }

    sqlx::raw_sql("DROP TABLE currentchanges")
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
               p.declfile, p.decltype, p.declvalue
        FROM jobsets j
        JOIN projects p ON j.project = p.name
        WHERE j.project = $1 AND j.name = $2"#,
        project,
        jobset,
    )
    .fetch_optional(conn.raw())
    .await
}

/// The jobset's most recent evaluation, if any.
pub(crate) async fn get_latest_eval(
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

/// The jobset's most recent evaluation that had new builds. Only such an
/// evaluation has members to compare jobs against; one without new builds
/// records none.
pub(crate) async fn get_previous_eval_with_new_builds(
    conn: &mut db::Connection,
    jobset_id: i32,
) -> Result<Option<PreviousEval>, sqlx::Error> {
    sqlx::query_as!(
        PreviousEval,
        r#"
        SELECT id, hash, flake FROM jobsetevals
        WHERE jobset_id = $1 AND hasnewbuilds = 1
        ORDER BY id DESC
        LIMIT 1"#,
        jobset_id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// How many jobs the previous evaluation covered.
pub(crate) async fn count_eval_members(
    tx: &mut db::Transaction<'_>,
    eval: i32,
) -> Result<i64, sqlx::Error> {
    Ok(sqlx::query!(
        r#"SELECT COUNT(*) as "n!" FROM jobsetevalmembers WHERE eval = $1"#,
        eval,
    )
    .fetch_one(tx.raw())
    .await?
    .n)
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

/// Mark an evaluation attempt as over by clearing `triggerTime` and
/// `startTime`.
///
/// Runs in a transaction so that a partial failure cannot clear
/// `triggerTime` but leave `startTime` set, which would make the
/// jobset appear permanently running.
pub(crate) async fn update_jobset_after_eval(
    conn: &mut db::Connection,
    jobset_id: i32,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    let mut tx = conn.raw().begin().await?;

    clear_trigger_time(&mut tx, jobset_id).await?;

    sqlx::query!(
        "UPDATE jobsets SET startTime = null, lastCheckedTime = $2 WHERE id = $1",
        jobset_id,
        now,
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}

/// Set the jobset's evaluation error, empty for none, and return whether it
/// differs from the one before. Like the Perl's `setJobsetError`, this also
/// clears the fetch error.
///
/// Whether the error changed decides whether anyone is told about it, and
/// once the row is written it cannot be worked out. Locking the row first
/// stops another evaluation racing the comparison.
pub(crate) async fn set_jobset_error(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    error_msg: &str,
    now: db::Timestamp,
) -> Result<bool, sqlx::Error> {
    let previous = sqlx::query_scalar!(
        "SELECT errorMsg FROM jobsets WHERE id = $1 FOR UPDATE",
        jobset_id,
    )
    .fetch_optional(tx.raw())
    .await?
    .flatten()
    .unwrap_or_default();

    sqlx::query!(
        "UPDATE jobsets SET errorMsg = $2, errorTime = $3, fetchErrorMsg = null WHERE id = $1",
        jobset_id,
        error_msg,
        now,
    )
    .execute(tx.raw())
    .await?;
    Ok(error_msg != previous)
}

/// Set or clear the jobset's fetch error, leaving its evaluation error alone.
pub(crate) async fn set_fetch_error(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    error_msg: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET fetchErrorMsg = $2 WHERE id = $1",
        jobset_id,
        error_msg,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Clear `forceEval` and disable a one-shot jobset, after an evaluation that
/// actually ran.
pub(crate) async fn finish_jobset_eval(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET forceEval = null, \
           enabled = CASE WHEN enabled = 2 THEN 0 ELSE enabled END \
         WHERE id = $1",
        jobset_id,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Record that an evaluation failed, and tell listeners. One transaction,
/// because `NOTIFY` is delivered on commit.
pub(crate) async fn fail_jobset_eval(
    conn: &mut db::Connection,
    trace: &str,
    jobset_id: i32,
    error_msg: &str,
    now: db::Timestamp,
) -> Result<(), db::Error> {
    let mut tx = conn.begin_transaction().await?;
    clear_trigger_time(tx.raw(), jobset_id).await?;
    sqlx::query!(
        "UPDATE jobsets SET startTime = null, lastCheckedTime = $2 WHERE id = $1",
        jobset_id,
        now,
    )
    .execute(tx.raw())
    .await?;
    let changed = set_jobset_error(&mut tx, jobset_id, error_msg, now).await?;
    tx.notify_eval_failed(trace, jobset_id, changed).await?;

    tx.commit().await?;
    Ok(())
}

/// Clear `triggerTime` if it was set before this evaluation started, so a
/// trigger the evaluation already served does not start another, which would
/// be a stuck evaluation loop.
async fn clear_trigger_time(
    conn: &mut sqlx::PgConnection,
    jobset_id: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET triggerTime = null \
         WHERE id = $1 AND startTime IS NOT NULL AND triggerTime <= startTime",
        jobset_id,
    )
    .execute(conn)
    .await?;
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
    /// The type and value of the input holding `declfile`.
    pub decltype: Option<String>,
    pub declvalue: Option<String>,
}

/// The previous evaluation, for deciding whether to evaluate again.
#[derive(Debug)]
pub(crate) struct PreviousEval {
    pub id: i32,
    pub hash: String,
    pub flake: Option<String>,
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
}

/// Record the evaluation itself, returning its id.
pub(crate) async fn insert_eval(
    tx: &mut db::Transaction<'_>,
    eval: &NewEval<'_>,
    evaluation_error_id: i32,
) -> Result<i32, sqlx::Error> {
    let now = jiff::Timestamp::now().as_second();

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
        evaluation_error_id,
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

/// The inputs this evaluation was performed with, recorded so that the
/// evaluation remains reproducible after they move on.
pub(crate) async fn insert_eval_input(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    name: &str,
    alt_nr: i32,
    input: &crate::inputs::JobsetInput,
    store_dir: &db::StoreDir,
) -> Result<(), sqlx::Error> {
    let short_rev_length = input
        .short_rev
        .as_ref()
        .and_then(|r| i16::try_from(r.len()).ok());
    // Stored as a full path, which is what the schema's store path columns
    // hold; the fetcher reports bare names.
    let path = input
        .store_path
        .as_deref()
        .map(|p| crate::nix_eval_jobs::full(store_dir, p));
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
        path,
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
