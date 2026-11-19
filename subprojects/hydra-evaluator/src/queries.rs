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
/// Finds the rows to change once, then updates them in batches to keep each
/// statement's locks short. A row that changed in between is skipped.
pub(crate) async fn mark_current(
    conn: &mut db::Connection,
    jobset_id: i32,
    eval: i32,
    batch: usize,
) -> Result<(), sqlx::Error> {
    let to_set = sqlx::query_scalar!(
        r#"
        SELECT b.id FROM builds b
        JOIN jobsetevalmembers m ON m.build = b.id
        WHERE m.eval = $1 AND b.iscurrent = 0
        ORDER BY b.id"#,
        eval,
    )
    .fetch_all(conn.raw())
    .await?;
    set_current(conn, &to_set, 1, batch).await?;

    let to_clear = sqlx::query_scalar!(
        r#"
        SELECT b.id FROM builds b
        WHERE b.jobset_id = $1 AND b.iscurrent = 1
          AND NOT EXISTS (
            SELECT 1 FROM jobsetevalmembers m
            WHERE m.eval = $2 AND m.build = b.id)
        ORDER BY b.id"#,
        jobset_id,
        eval,
    )
    .fetch_all(conn.raw())
    .await?;
    set_current(conn, &to_clear, 0, batch).await
}

/// Set `iscurrent` on these builds, a batch per statement.
async fn set_current(
    conn: &mut db::Connection,
    ids: &[i32],
    value: i32,
    batch: usize,
) -> Result<(), sqlx::Error> {
    for chunk in ids.chunks(batch) {
        sqlx::query!(
            "UPDATE builds SET iscurrent = $1 WHERE id = ANY($2) AND iscurrent <> $1",
            value,
            chunk,
        )
        .execute(conn.raw())
        .await?;
    }
    Ok(())
}

/// Point a build at the derivation this evaluation found for it, and put
/// it back in the queue.
pub(crate) async fn repoint_build(
    tx: &mut db::Transaction<'_>,
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
    .execute(tx.raw())
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

/// One output of a build in an earlier evaluation.
#[derive(Debug)]
pub(crate) struct PreviousOutput {
    pub id: i32,
    pub job: String,
    pub finished: i32,
    pub drvpath: String,
    pub name: String,
    /// None for a content-addressed output not built yet.
    pub path: Option<String>,
}

/// Everything needed to queue a build. The `meta` fields are all optional,
/// because a jobset may set none of them.
#[derive(Debug)]
pub(crate) struct NewBuild<'a> {
    pub job: &'a str,
    pub drv_path: &'a str,
    pub system: &'a str,
    pub nix_name: Option<&'a str>,
    pub description: Option<&'a str>,
    pub license: Option<&'a str>,
    pub homepage: Option<&'a str>,
    pub maintainers: Option<&'a str>,
    pub max_silent: Option<i32>,
    pub timeout: Option<i32>,
    pub priority: i32,
    pub is_channel: i32,
    /// Output name to path, as `nix-eval-jobs` reports them.
    pub outputs: &'a std::collections::BTreeMap<String, Option<String>>,
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

/// Every output of every build of an evaluation, for the next one to match
/// its jobs against.
pub(crate) async fn get_eval_outputs(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    jobset_id: i32,
) -> Result<Vec<PreviousOutput>, sqlx::Error> {
    // The jobset constraint is implied by the evaluation, but stating it
    // lets the planner use the builds' jobset index.
    sqlx::query_as!(
        PreviousOutput,
        r#"
        SELECT b.id, b.job, b.finished, b.drvpath, o.name, o.path as "path?"
        FROM jobsetevalmembers m
        JOIN builds b ON m.build = b.id
        JOIN buildoutputs o ON o.build = b.id
        WHERE m.eval = $1 AND b.jobset_id = $2"#,
        eval,
        jobset_id,
    )
    .fetch_all(tx.raw())
    .await
}

/// Queue builds with their outputs, returning their ids in the order given.
/// `(job, drv_path)` must be unique among `builds`, which `ingest`'s dedup
/// ensures.
pub(crate) async fn insert_builds(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    builds: &[NewBuild<'_>],
) -> Result<Vec<i32>, sqlx::Error> {
    fn column<'b, 'a: 'b, T>(
        builds: &'b [NewBuild<'a>],
        f: impl Fn(&'b NewBuild<'a>) -> T,
    ) -> Vec<T> {
        builds.iter().map(f).collect()
    }

    if builds.is_empty() {
        return Ok(Vec::new());
    }

    // Unchecked, like `insert_build_outputs`, because the checked macro
    // takes no arrays with nulls in them.
    let rows: Vec<(i32, String, String)> = sqlx::query_as(
        r"
        INSERT INTO builds
          (timestamp, jobset_id, job, drvpath, system, nixname, description,
           license, homepage, maintainers, maxsilent, timeout, priority,
           finished, iscurrent, ischannel)
        SELECT $1, $2, job, drvpath, system, nixname, description,
               license, homepage, maintainers, maxsilent, timeout, priority,
               0, 1, ischannel
        FROM UNNEST($3::text[], $4::text[], $5::text[], $6::text[], $7::text[],
                    $8::text[], $9::text[], $10::text[], $11::int[], $12::int[],
                    $13::int[], $14::int[])
          AS t(job, drvpath, system, nixname, description, license, homepage,
               maintainers, maxsilent, timeout, priority, ischannel)
        RETURNING id, job, drvpath",
    )
    .bind(jiff::Timestamp::now().as_second())
    .bind(jobset_id)
    .bind(column(builds, |b| b.job))
    .bind(column(builds, |b| b.drv_path))
    .bind(column(builds, |b| b.system))
    .bind(column(builds, |b| b.nix_name))
    .bind(column(builds, |b| b.description))
    .bind(column(builds, |b| b.license))
    .bind(column(builds, |b| b.homepage))
    .bind(column(builds, |b| b.maintainers))
    .bind(column(builds, |b| b.max_silent))
    .bind(column(builds, |b| b.timeout))
    .bind(column(builds, |b| b.priority))
    .bind(column(builds, |b| b.is_channel))
    .fetch_all(tx.raw())
    .await?;

    // Postgres doesn't promise RETURNING follows the input order, so match
    // the rows back to `builds` by key.
    let index: std::collections::HashMap<(&str, &str), usize> = builds
        .iter()
        .enumerate()
        .map(|(i, b)| ((b.job, b.drv_path), i))
        .collect();
    debug_assert_eq!(index.len(), builds.len(), "duplicate (job, drv_path)");
    let mut ids = vec![0; builds.len()];
    for (id, job, drv_path) in rows {
        ids[index[&(job.as_str(), drv_path.as_str())]] = id;
    }

    let mut outputs = NewOutputs::default();
    for (build, id) in builds.iter().zip(&ids) {
        for (name, path) in build.outputs {
            outputs.builds.push(*id);
            outputs.names.push(name);
            outputs.paths.push(path.as_deref());
        }
    }
    insert_build_outputs(tx, &outputs).await?;
    Ok(ids)
}

/// Outputs of the builds an evaluation queued, as parallel columns. Kept
/// together so they can be written in one statement.
#[derive(Debug, Default)]
struct NewOutputs<'a> {
    builds: Vec<i32>,
    names: Vec<&'a str>,
    paths: Vec<Option<&'a str>>,
}

/// Record the outputs of every build an evaluation queued, in one statement,
/// because a row at a time dominates insertion time on a large jobset.
async fn insert_build_outputs(
    tx: &mut db::Transaction<'_>,
    outputs: &NewOutputs<'_>,
) -> Result<(), sqlx::Error> {
    // Unchecked, because the checked macro will not take an array with nulls
    // in it as a parameter, and a content-addressed output's path is null.
    sqlx::query(
        "INSERT INTO buildoutputs (build, name, path) \
         SELECT * FROM UNNEST($1::int[], $2::text[], $3::text[])",
    )
    .bind(&outputs.builds)
    .bind(&outputs.names)
    .bind(&outputs.paths)
    .execute(tx.raw())
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::NewBuild;

    fn build<'a>(
        job: &'a str,
        drv_path: &'a str,
        outputs: &'a BTreeMap<String, Option<String>>,
    ) -> NewBuild<'a> {
        NewBuild {
            job,
            drv_path,
            system: "x86_64-linux",
            nix_name: None,
            description: None,
            license: None,
            homepage: None,
            maintainers: None,
            max_silent: None,
            timeout: None,
            priority: 100,
            is_channel: 0,
            outputs,
        }
    }

    #[tokio::test]
    async fn insert_builds_returns_each_builds_own_id() {
        type Row = (
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i32>,
            Option<i32>,
            i32,
            i32,
        );

        let (pg, _pool) = test_utils::TestPg::new().await;
        let db = db::Database::new(&pg.url(), 1).await.unwrap();
        let mut conn = db.get().await.unwrap();
        let mut tx = conn.begin_transaction().await.unwrap();
        // Replica role skips the foreign keys, so no jobset is needed.
        sqlx::query("SET session_replication_role = 'replica'")
            .execute(tx.raw())
            .await
            .unwrap();

        let a1_out = BTreeMap::from([("out".to_owned(), Some("/nix/store/a1".to_owned()))]);
        // Content-addressed: no path yet.
        let a2_out = BTreeMap::from([("out".to_owned(), None)]);
        let b_out = BTreeMap::from([
            ("dev".to_owned(), Some("/nix/store/b-dev".to_owned())),
            ("out".to_owned(), Some("/nix/store/b".to_owned())),
        ]);
        let builds = [
            NewBuild {
                nix_name: Some("a-1"),
                description: Some("desc"),
                license: Some("mit"),
                homepage: Some("https://a"),
                maintainers: Some("alice"),
                max_silent: Some(10),
                timeout: Some(20),
                priority: 5,
                is_channel: 1,
                ..build("a", "a1.drv", &a1_out)
            },
            // Same job, other derivation: a build of its own.
            build("a", "a2.drv", &a2_out),
            build("b", "b.drv", &b_out),
        ];
        let ids = super::insert_builds(&mut tx, 1, &builds).await.unwrap();

        let rows: Vec<Row> = sqlx::query_as(
            "SELECT job, drvpath, nixname, description, license, homepage,
                    maintainers, maxsilent, timeout, priority, ischannel
             FROM builds WHERE id = ANY($1) ORDER BY array_position($1, id)",
        )
        .bind(&ids)
        .fetch_all(tx.raw())
        .await
        .unwrap();
        let s = |s: &str| Some(s.to_owned());
        let none = |job: &str, drv: &str| {
            let (job, drv) = (job.to_owned(), drv.to_owned());
            (job, drv, None, None, None, None, None, None, None, 100, 0)
        };
        assert_eq!(
            rows,
            [
                (
                    "a".to_owned(),
                    "a1.drv".to_owned(),
                    s("a-1"),
                    s("desc"),
                    s("mit"),
                    s("https://a"),
                    s("alice"),
                    Some(10),
                    Some(20),
                    5,
                    1,
                ),
                none("a", "a2.drv"),
                none("b", "b.drv"),
            ]
        );

        let outputs: Vec<(i32, String, Option<String>)> =
            sqlx::query_as("SELECT build, name, path FROM buildoutputs ORDER BY build, name")
                .fetch_all(tx.raw())
                .await
                .unwrap();
        let mut expected = vec![
            (ids[0], "out".to_owned(), s("/nix/store/a1")),
            (ids[1], "out".to_owned(), None),
            (ids[2], "dev".to_owned(), s("/nix/store/b-dev")),
            (ids[2], "out".to_owned(), s("/nix/store/b")),
        ];
        expected.sort();
        assert_eq!(outputs, expected);
    }
}
