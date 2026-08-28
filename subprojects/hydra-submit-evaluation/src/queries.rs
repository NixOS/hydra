//! Compile-time-checked queries for submitting evaluations: which jobsets
//! are due, what they are configured with, and the rows that queue one.

use crate::inputs::JobsetInput;

/// A jobset that should be evaluated now.
#[derive(Debug)]
pub(crate) struct DueJobset {
    pub(crate) id: i32,
    pub(crate) project: String,
    pub(crate) name: String,
}

/// The jobsets due for evaluation, most urgent first.
///
/// Due means triggered, or enabled with a check interval that has elapsed. A
/// one-at-a-time jobset also waits for its last evaluation to be over: the
/// evaluation build still running, or builds it queued still unfinished, both
/// mean it is not. A trigger overrides that, as it always did.
pub(crate) async fn get_due_jobsets(
    conn: &mut db::Connection,
    now: db::Timestamp,
) -> Result<Vec<DueJobset>, sqlx::Error> {
    sqlx::query_as!(
        DueJobset,
        r#"
        SELECT j.id, j.project, j.name
        FROM jobsets j
        JOIN projects p ON j.project = p.name
        WHERE j.enabled IN (1, 2, 3) AND p.enabled != 0
          AND (j.triggertime IS NOT NULL
               OR (j.checkinterval > 0
                   AND coalesce(j.lastcheckedtime, 0) + j.checkinterval <= $1
                   AND NOT (j.enabled = 3 AND EXISTS (
                     SELECT 1 FROM jobsetevals e
                     WHERE e.id = (SELECT max(id) FROM jobsetevals WHERE jobset_id = j.id)
                       AND ((e.eval_build IS NOT NULL AND e.completed IS NULL)
                            OR EXISTS (
                              SELECT 1 FROM jobsetevalmembers m
                              JOIN builds b ON b.id = m.build
                              WHERE m.eval = e.id AND b.finished = 0))))))
        ORDER BY j.triggertime NULLS LAST, j.lastcheckedtime NULLS FIRST, j.id"#,
        now,
    )
    .fetch_all(conn.raw())
    .await
}

/// What a jobset says to evaluate.
#[derive(Debug)]
pub(crate) struct JobsetForEval {
    pub(crate) id: i32,
    pub(crate) flake: Option<String>,
    pub(crate) nixexprinput: Option<String>,
    pub(crate) nixexprpath: Option<String>,
    pub(crate) forceeval: Option<bool>,
    pub(crate) declfile: Option<String>,
    /// The type and value of the input holding `declfile`.
    pub(crate) decltype: Option<String>,
    pub(crate) declvalue: Option<String>,
}

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

/// A jobset input as configured, before it is resolved.
#[derive(Debug)]
pub(crate) struct ConfiguredInputRow {
    pub(crate) name: String,
    pub(crate) r#type: String,
    pub(crate) value: Option<String>,
    pub(crate) emailresponsible: i32,
}

/// A jobset's configured inputs, with their alternatives, in the order
/// they should be resolved.
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

/// What a `build`, `sysbuild` or `eval` input needs to know about a build.
#[derive(Debug)]
pub(crate) struct InputBuild {
    pub(crate) id: i32,
    pub(crate) releasename: Option<String>,
    pub(crate) nixname: Option<String>,
    pub(crate) out_path: Option<String>,
    pub(crate) out_name: Option<String>,
}

/// A build by id, for a `build` input given a number.
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

/// Whether the evaluation an `eval` input names by id exists.
pub(crate) async fn eval_exists(conn: &mut db::Connection, id: i32) -> Result<bool, sqlx::Error> {
    Ok(sqlx::query!("SELECT id FROM jobsetevals WHERE id = $1", id)
        .fetch_optional(conn.raw())
        .await?
        .is_some())
}

/// The most recent evaluation of a jobset all of whose builds have
/// finished -- what an `eval` input means by `project:jobset` -- or, given
/// a job, one in which that job succeeded.
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

/// The previous evaluation, for deciding whether to evaluate again.
#[derive(Debug)]
pub(crate) struct PreviousEval {
    pub(crate) id: i32,
    pub(crate) hash: String,
    pub(crate) flake: Option<String>,
}

/// The jobset's most recent evaluation, whose hash says whether these
/// inputs have been evaluated before. Scheduled counts as much as finished:
/// the same inputs are already on their way.
pub(crate) async fn get_previous_eval(
    conn: &mut db::Connection,
    jobset_id: i32,
) -> Result<Option<PreviousEval>, sqlx::Error> {
    sqlx::query_as!(
        PreviousEval,
        "SELECT id, hash, flake FROM jobsetevals WHERE jobset_id = $1 ORDER BY id DESC LIMIT 1",
        jobset_id,
    )
    .fetch_optional(conn.raw())
    .await
}

/// Record that the jobset was checked.
///
/// A trigger from before this submission started is consumed by it; one that
/// arrived meanwhile is kept, so the jobset is submitted again. `forceEval`
/// asked for the one evaluation just submitted, so it is done with too.
pub(crate) async fn record_checked(
    conn: &mut db::Connection,
    jobset_id: i32,
    started: db::Timestamp,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobsets SET lastcheckedtime = $3, forceeval = NULL, \
           triggertime = CASE WHEN triggertime <= $2 THEN NULL ELSE triggertime END \
         WHERE id = $1",
        jobset_id,
        started,
        now,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Record that a declarative specification named the jobsets outright.
///
/// There is nothing to evaluate, so no later step will clear the jobset's
/// error the way completing an evaluation does; whatever a previous attempt
/// at the specification recorded is over and is cleared here.
pub(crate) async fn record_declared(
    conn: &mut db::Connection,
    jobset_id: i32,
    started: db::Timestamp,
    now: db::Timestamp,
) -> Result<(), sqlx::Error> {
    record_checked(conn, jobset_id, started, now).await?;
    sqlx::query!(
        "UPDATE jobsets SET errormsg = '', errortime = NULL, fetcherrormsg = NULL WHERE id = $1",
        jobset_id,
    )
    .execute(conn.raw())
    .await?;
    Ok(())
}

/// Record that submitting an evaluation failed, and tell listeners.
///
/// The notification carries whether the error differs from the one the
/// jobset already had, because that decides whether anyone is told about
/// it and it cannot be worked out afterwards -- by then the row holds the
/// new error. Reading the old one, writing the new one and announcing it
/// are one transaction, both so the flag cannot race another evaluation
/// and because `NOTIFY` is delivered on commit.
pub(crate) async fn record_failed(
    conn: &mut db::Connection,
    trace: &str,
    jobset_id: i32,
    error_msg: &str,
    started: db::Timestamp,
    now: db::Timestamp,
) -> Result<(), db::Error> {
    let mut tx = conn.begin_transaction().await?;

    let previous = sqlx::query_scalar!(
        "SELECT errormsg FROM jobsets WHERE id = $1 FOR UPDATE",
        jobset_id,
    )
    .fetch_optional(tx.raw())
    .await?
    .flatten()
    .unwrap_or_default();

    sqlx::query!(
        "UPDATE jobsets SET lastcheckedtime = $3, forceeval = NULL, \
           triggertime = CASE WHEN triggertime <= $2 THEN NULL ELSE triggertime END, \
           errormsg = $4, errortime = $3, fetcherrormsg = NULL \
         WHERE id = $1",
        jobset_id,
        started,
        now,
        error_msg,
    )
    .execute(tx.raw())
    .await?;

    tx.notify_eval_failed(trace, jobset_id, error_msg != previous)
        .await?;

    tx.commit().await?;
    Ok(())
}

/// The hidden jobset that evaluation builds belong to, created on first use.
///
/// They are builds and so must live in some jobset, but they are not anyone's
/// jobs: this keeps them out of the jobsets people look at. Disabled, or the
/// scheduler would submit an evaluation of it.
pub(crate) async fn ensure_eval_jobset(conn: &mut db::Connection) -> Result<i32, sqlx::Error> {
    sqlx::query!(
        "INSERT INTO projects (name, displayName, description, enabled, hidden, owner)
         VALUES ('hydra', 'Hydra', 'Hydra internals', 0, 1, 'root')
         ON CONFLICT (name) DO NOTHING"
    )
    .execute(conn.raw())
    .await?;

    sqlx::query!(
        "INSERT INTO jobsets (project, name, description, nixexprinput, nixexprpath,
                              enabled, hidden, checkinterval, triggertime, type, emailoverride)
         VALUES ('hydra', 'evaluations', 'Evaluations run as builds', '', '', 0, 1, 0, null, 0, '')
         ON CONFLICT (project, name) DO NOTHING"
    )
    .execute(conn.raw())
    .await?;

    Ok(
        sqlx::query!("SELECT id FROM jobsets WHERE project = 'hydra' AND name = 'evaluations'")
            .fetch_one(conn.raw())
            .await?
            .id,
    )
}

/// Queue the build that will perform an evaluation.
///
/// The queue runner only ever *updates* a build's output row -- it fills in
/// the path once there is one -- so the row has to exist first. The single
/// `out` is the JSONL the evaluation produces.
pub(crate) async fn insert_eval_build(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    job: &str,
    drv_path: &str,
    system: &str,
    now: db::Timestamp,
) -> Result<i32, sqlx::Error> {
    let id = sqlx::query!(
        r#"
        INSERT INTO builds
          (timestamp, jobset_id, job, nixname, drvpath, system, priority,
           globalpriority, finished, iscurrent)
        VALUES ($1, $2, $3, 'hydra-eval', $4, $5, 100, 0, 0, 1)
        RETURNING id"#,
        now,
        jobset_id,
        job,
        drv_path,
        system,
    )
    .fetch_one(tx.raw())
    .await?
    .id;

    sqlx::query!(
        "INSERT INTO buildoutputs (build, name, path) VALUES ($1, 'out', null)",
        id,
    )
    .execute(tx.raw())
    .await?;

    Ok(id)
}

/// The evaluation row, as it is first written: what is being evaluated and
/// with what, before anything is known about the result.
#[derive(Debug)]
pub(crate) struct NewEval<'a> {
    pub(crate) jobset_id: i32,
    pub(crate) checkout_time: i32,
    pub(crate) hash: &'a str,
    pub(crate) flake: Option<&'a str>,
    pub(crate) nix_expr_input: Option<&'a str>,
    pub(crate) nix_expr_path: Option<&'a str>,
    /// The build that will perform this evaluation, and fill the row in.
    pub(crate) eval_build: i32,
    /// So the pass that completes this evaluation reports against the same
    /// trace as the one that scheduled it.
    pub(crate) trace_id: &'a str,
}

/// Record a tentative evaluation, returning its id.
///
/// `hasnewbuilds` is a placeholder and `completed` is null until the build
/// has been read back. The error record is created empty now so the row can
/// point at it; completion fills it in.
pub(crate) async fn insert_eval(
    tx: &mut db::Transaction<'_>,
    eval: &NewEval<'_>,
    now: db::Timestamp,
) -> Result<i32, sqlx::Error> {
    let error_id = sqlx::query!(
        "INSERT INTO evaluationerrors (errormsg, errortime) VALUES ('', $1) RETURNING id",
        now,
    )
    .fetch_one(tx.raw())
    .await?
    .id;

    Ok(sqlx::query!(
        r#"
        INSERT INTO jobsetevals
          (jobset_id, timestamp, checkouttime, evaltime, hasnewbuilds, nrbuilds,
           hash, flake, nixexprinput, nixexprpath, evaluationerror_id,
           eval_build, trace_id)
        -- `evaltime` is written once and never maintained: how long an
        -- evaluation took is how long its build took, which the build knows.
        VALUES ($1, $2, $3, 0, 0, 0, $4, $5, $6, $7, $8, $9, $10)
        RETURNING id"#,
        eval.jobset_id,
        now,
        eval.checkout_time,
        eval.hash,
        eval.flake,
        eval.nix_expr_input,
        eval.nix_expr_path,
        error_id,
        eval.eval_build,
        eval.trace_id,
    )
    .fetch_one(tx.raw())
    .await?
    .id)
}

/// The inputs this evaluation was performed with, recorded so that the
/// evaluation remains reproducible after they move on.
///
/// `path` is stored as a full path, which is what the schema's store path
/// columns hold; the fetcher reports bare names.
pub(crate) async fn insert_eval_input(
    tx: &mut db::Transaction<'_>,
    eval: i32,
    name: &str,
    alt_nr: i32,
    input: &JobsetInput,
    store_dir: &str,
) -> Result<(), sqlx::Error> {
    let short_rev_length = input
        .short_rev
        .as_ref()
        .and_then(|r| i16::try_from(r.len()).ok());
    // Stored as a full path, which is what the schema's store path columns
    // hold; the fetcher reports bare names.
    let path = input.store_path.as_deref().map(|p| {
        if p.starts_with('/') {
            p.to_owned()
        } else {
            format!("{store_dir}/{p}")
        }
    });
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
