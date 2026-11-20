//! An evaluation's jobs, staged in temporary tables so that recording them
//! is a handful of set-based statements rather than a few round trips per
//! job.
//!
//! The jobs are written once, and everything after that -- which builds are
//! inherited from the previous evaluation, which are queued, the members,
//! aggregates and notifications -- is worked out by Postgres from these
//! tables. Nothing about them is read back into the evaluator.
//!
//! The tables are temporary, so they belong to one session:
//!
//! - `evaljobs`, `evaljoboutputs` and `evaljobconstituents` are created in
//!   the evaluation transaction and dropped when it ends, committed or not.
//!
//! - `evalrepoints` is created in the same transaction but outlives it, for
//!   the follow-up on the same connection to apply once the evaluation is
//!   committed. A connection that comes back from the pool may still have
//!   one from a follow-up that failed or was abandoned, so it is dropped
//!   before it is created.
//!
//! What this guarantees:
//!
//! - The evaluation is recorded atomically. Its builds, outputs, members,
//!   aggregates, error and notifications are all written in the one
//!   transaction, or none of them are.
//!
//! - Nothing durable depends on these tables. They are only ever read as
//!   input, by statements that commit on their own, so dropping one at any
//!   point leaves the database as some prefix of the work left it: stale
//!   perhaps, never inconsistent. A retried evaluation transaction starts
//!   without the first three, since rolling back also undoes their creation.
//!
//! - `evalrepoints` is the one that matters if lost: between the evaluation
//!   committing and [`repoint`] committing, it holds the only copy of the
//!   new derivations. Losing it, to a failed follow-up or a dropped
//!   connection, defers those repoints to the jobset's next evaluation that
//!   is not cached, which finds them again. [`repoint`] fails without it, so
//!   that the loss is recorded as the jobset's error; nothing else does.
//!
//! Every statement here is unchecked, because the checked macros cannot see
//! a temporary table: <https://github.com/launchbadge/sqlx/issues/3661>.
//! Once that is resolved, these can go back to `query!`.

use crate::nix_eval_jobs::Job;

/// The jobs to stage, as the parallel columns `UNNEST` takes. Each job's
/// position in the evaluation is its key, `ord`, in all three tables.
#[derive(Default)]
pub(crate) struct Jobs<'a> {
    ord: Vec<i32>,
    job: Vec<&'a str>,
    drv_path: Vec<&'a str>,
    system: Vec<&'a str>,
    nix_name: Vec<Option<&'a str>>,
    description: Vec<Option<&'a str>>,
    license: Vec<Option<&'a str>>,
    homepage: Vec<Option<&'a str>>,
    maintainers: Vec<Option<&'a str>>,
    max_silent: Vec<Option<i32>>,
    timeout: Vec<Option<i32>>,
    priority: Vec<i32>,
    is_channel: Vec<i32>,
    first_name: Vec<&'a str>,
    first_path: Vec<Option<&'a str>>,

    output_ord: Vec<i32>,
    output_name: Vec<&'a str>,
    output_path: Vec<Option<&'a str>>,

    constituent_ord: Vec<i32>,
    constituent_drv_path: Vec<&'a str>,
}

impl<'a> Jobs<'a> {
    /// Add a job that evaluated. `drv_path` and the first output are the
    /// caller's to check exist, since only it knows how to report them.
    pub(crate) fn push(
        &mut self,
        ord: i32,
        job: &'a Job,
        drv_path: &'a str,
        (first_name, first_path): (&'a str, Option<&'a str>),
    ) {
        let meta = &job.meta;
        self.ord.push(ord);
        self.job.push(&job.attr);
        self.drv_path.push(drv_path);
        self.system.push(job.system.as_deref().unwrap_or_default());
        self.nix_name
            .push(job.name.as_deref().or(meta.name.as_deref()));
        self.description.push(meta.description.as_deref());
        self.license.push(meta.license.as_deref());
        self.homepage.push(meta.homepage.as_deref());
        self.maintainers.push(meta.maintainers.as_deref());
        self.max_silent.push(meta.max_silent);
        self.timeout.push(meta.timeout);
        self.priority.push(meta.priority);
        self.is_channel.push(meta.is_channel);
        self.first_name.push(first_name);
        self.first_path.push(first_path);

        for (name, path) in &job.outputs {
            self.output_ord.push(ord);
            self.output_name.push(name);
            self.output_path.push(path.as_deref());
        }
        for constituent in job.constituents.iter().flatten() {
            self.constituent_ord.push(ord);
            self.constituent_drv_path.push(constituent);
        }
    }
}

/// Create the evaluation's tables and fill them with `jobs`.
///
/// Two attributes producing the same output are one build, so a job whose
/// name and first output (or derivation, for an output without a path yet)
/// repeat an earlier one's is not staged. `nix-eval-jobs` reports each
/// attribute once, so in practice this never drops anything.
pub(crate) async fn stage(
    tx: &mut db::Transaction<'_>,
    jobs: &Jobs<'_>,
) -> Result<(), sqlx::Error> {
    sqlx::raw_sql(
        "CREATE TEMP TABLE evaljobs (
           ord          integer PRIMARY KEY,
           job          text NOT NULL,
           drvpath      text NOT NULL,
           system       text NOT NULL,
           nixname      text,
           description  text,
           license      text,
           homepage     text,
           maintainers  text,
           maxsilent    integer,
           timeout      integer,
           priority     integer NOT NULL,
           ischannel    integer NOT NULL,
           firstname    text NOT NULL,
           firstpath    text,
           -- Set once the job's build is known, inherited or queued.
           build        integer,
           isnew        boolean NOT NULL DEFAULT false,
           -- The inherited build as the previous evaluation left it.
           prevfinished integer,
           prevdrvpath  text
         ) ON COMMIT DROP;
         CREATE UNIQUE INDEX ON evaljobs (job, coalesce(firstpath, drvpath));
         CREATE TEMP TABLE evaljoboutputs (
           ord  integer NOT NULL,
           name text NOT NULL,
           path text
         ) ON COMMIT DROP;
         CREATE TEMP TABLE evaljobconstituents (
           ord     integer NOT NULL,
           drvpath text NOT NULL
         ) ON COMMIT DROP;",
    )
    .execute(tx.raw())
    .await?;

    sqlx::query(
        "INSERT INTO evaljobs
           (ord, job, drvpath, system, nixname, description, license, homepage,
            maintainers, maxsilent, timeout, priority, ischannel, firstname,
            firstpath)
         SELECT * FROM UNNEST($1::int[], $2::text[], $3::text[], $4::text[],
                              $5::text[], $6::text[], $7::text[], $8::text[],
                              $9::text[], $10::int[], $11::int[], $12::int[],
                              $13::int[], $14::text[], $15::text[])
         ORDER BY 1
         ON CONFLICT DO NOTHING",
    )
    .bind(&jobs.ord)
    .bind(&jobs.job)
    .bind(&jobs.drv_path)
    .bind(&jobs.system)
    .bind(&jobs.nix_name)
    .bind(&jobs.description)
    .bind(&jobs.license)
    .bind(&jobs.homepage)
    .bind(&jobs.maintainers)
    .bind(&jobs.max_silent)
    .bind(&jobs.timeout)
    .bind(&jobs.priority)
    .bind(&jobs.is_channel)
    .bind(&jobs.first_name)
    .bind(&jobs.first_path)
    .execute(tx.raw())
    .await?;

    sqlx::query(
        "INSERT INTO evaljoboutputs (ord, name, path)
         SELECT * FROM UNNEST($1::int[], $2::text[], $3::text[])",
    )
    .bind(&jobs.output_ord)
    .bind(&jobs.output_name)
    .bind(&jobs.output_path)
    .execute(tx.raw())
    .await?;

    sqlx::query(
        "INSERT INTO evaljobconstituents (ord, drvpath)
         SELECT * FROM UNNEST($1::int[], $2::text[])",
    )
    .bind(&jobs.constituent_ord)
    .bind(&jobs.constituent_drv_path)
    .execute(tx.raw())
    .await?;

    // Temporary tables are never analyzed automatically, and the joins
    // below against `builds` are planned badly without statistics.
    sqlx::raw_sql("ANALYZE evaljobs, evaljoboutputs, evaljobconstituents")
        .execute(tx.raw())
        .await?;
    Ok(())
}

/// Find each job's build in the previous evaluation, if it has one.
///
/// A job inherits the build of the same name whose first output has the same
/// path, or, for an output without a path yet, whose derivation is the same.
/// Several builds can match; the oldest is taken, which is as arbitrary as
/// any but at least stable.
pub(crate) async fn inherit(
    tx: &mut db::Transaction<'_>,
    prev_eval: i32,
    jobset_id: i32,
) -> Result<(), sqlx::Error> {
    // The jobset constraint is implied by the evaluation, but stating it
    // lets the planner use the builds' jobset index.
    sqlx::query(
        "UPDATE evaljobs j
         SET build = p.id, prevfinished = p.finished, prevdrvpath = p.drvpath
         FROM (
           SELECT DISTINCT ON (j.ord) j.ord, b.id, b.finished, b.drvpath
           FROM evaljobs j
           JOIN builds b ON b.jobset_id = $2 AND b.job = j.job
           JOIN jobsetevalmembers m ON m.build = b.id AND m.eval = $1
           JOIN buildoutputs o ON o.build = b.id AND o.name = j.firstname
           WHERE (j.firstpath IS NULL AND b.drvpath = j.drvpath)
              OR o.path = j.firstpath
           ORDER BY j.ord, b.id
         ) p
         WHERE j.ord = p.ord",
    )
    .bind(prev_eval)
    .bind(jobset_id)
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Queue a build, with its outputs, for every job that inherited none.
pub(crate) async fn queue_new(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
) -> Result<(), sqlx::Error> {
    // Ids are taken up front, so that each job's row says which build it
    // became without matching the inserted builds back to it.
    sqlx::query(
        "UPDATE evaljobs j SET build = n.id, isnew = true
         FROM (
           SELECT ord, nextval(pg_get_serial_sequence('builds', 'id'))::integer AS id
           FROM evaljobs WHERE build IS NULL ORDER BY ord
         ) n
         WHERE j.ord = n.ord",
    )
    .execute(tx.raw())
    .await?;

    sqlx::query(
        "INSERT INTO builds
           (id, timestamp, jobset_id, job, drvpath, system, nixname,
            description, license, homepage, maintainers, maxsilent, timeout,
            priority, finished, iscurrent, ischannel)
         SELECT build, $1, $2, job, drvpath, system, nixname,
                description, license, homepage, maintainers, maxsilent, timeout,
                priority, 0, 1, ischannel
         FROM evaljobs WHERE isnew ORDER BY ord",
    )
    .bind(jiff::Timestamp::now().as_second())
    .bind(jobset_id)
    .execute(tx.raw())
    .await?;

    sqlx::query(
        "INSERT INTO buildoutputs (build, name, path)
         SELECT j.build, o.name, o.path
         FROM evaljoboutputs o JOIN evaljobs j USING (ord)
         WHERE j.isnew",
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Announce every build of the evaluation, queued or inherited. The
/// payloads are what `Hydra::Event::BuildQueued`, `CachedBuildQueued` and
/// `CachedBuildFinished` parse.
///
/// An inherited build counts as finished only if its derivation is
/// unchanged: one that is about to be repointed will be built again.
pub(crate) async fn notify_builds(
    tx: &mut db::Transaction<'_>,
    eval: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "SELECT pg_notify('build_queued', build::text)
         FROM evaljobs WHERE isnew ORDER BY ord",
    )
    .execute(tx.raw())
    .await?;
    sqlx::query(
        "SELECT pg_notify(
                  CASE WHEN prevfinished <> 0 AND prevdrvpath = drvpath
                       THEN 'cached_build_finished'
                       ELSE 'cached_build_queued' END,
                  $1::text || E'\\t' || build)
         FROM evaljobs WHERE NOT isnew ORDER BY ord",
    )
    .bind(eval)
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// How many jobs were staged, and whether any of them queued a build.
pub(crate) async fn summary(tx: &mut db::Transaction<'_>) -> Result<(i64, bool), sqlx::Error> {
    sqlx::query_as("SELECT count(*), coalesce(bool_or(isnew), false) FROM evaljobs")
        .fetch_one(tx.raw())
        .await
}

/// Make every staged job a member of the evaluation.
pub(crate) async fn insert_members(
    tx: &mut db::Transaction<'_>,
    eval: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO jobsetevalmembers (eval, build, isnew)
         SELECT $1, build, isnew::integer FROM evaljobs",
    )
    .bind(eval)
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Link each aggregate to its constituents.
///
/// Jobs can alias one another, so several may share a derivation. When they
/// do, the shortest name wins -- ties broken bytewise -- so that an
/// aggregate points at the most canonical of them rather than an arbitrary
/// one. A pair already present is skipped: an aggregate inherited from an
/// earlier evaluation has its constituents already.
pub(crate) async fn insert_aggregates(tx: &mut db::Transaction<'_>) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"WITH canonical AS (
             SELECT DISTINCT ON (drvpath) drvpath, build FROM evaljobs
             ORDER BY drvpath, octet_length(job), job COLLATE "C")
           INSERT INTO aggregateconstituents (aggregate, constituent)
           SELECT a.build, c.build
           FROM evaljobconstituents ec
           JOIN evaljobs j USING (ord)
           JOIN canonical a ON a.drvpath = j.drvpath
           JOIN canonical c ON c.drvpath = ec.drvpath
           ON CONFLICT (aggregate, constituent) DO NOTHING"#,
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Constituents that are not any job of the evaluation, as (aggregate,
/// constituent derivation) pairs. Only worth asking for when logging them.
pub(crate) async fn missing_constituents(
    tx: &mut db::Transaction<'_>,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT j.job, ec.drvpath
         FROM evaljobconstituents ec JOIN evaljobs j USING (ord)
         WHERE NOT EXISTS (SELECT 1 FROM evaljobs x WHERE x.drvpath = ec.drvpath)
         ORDER BY j.ord",
    )
    .fetch_all(tx.raw())
    .await
}

/// Keep the inherited builds whose derivation changed, for [`repoint`] to
/// point at the new one once the evaluation is committed.
pub(crate) async fn stage_repoints(tx: &mut db::Transaction<'_>) -> Result<(), sqlx::Error> {
    sqlx::raw_sql(
        "DROP TABLE IF EXISTS pg_temp.evalrepoints;
         CREATE TEMP TABLE evalrepoints AS
           SELECT build AS id, drvpath FROM evaljobs
           WHERE NOT isnew AND prevdrvpath <> drvpath;",
    )
    .execute(tx.raw())
    .await?;
    Ok(())
}

/// Point the builds [`stage_repoints`] kept at their new derivations, and put
/// them back in the queue, returning how many there were.
///
/// Locks the rows in id order first, since the queue runner writes them too.
/// The `UPDATE` alone locks them in whatever order its plan visits them.
pub(crate) async fn repoint(tx: &mut db::Transaction<'_>) -> Result<u64, sqlx::Error> {
    sqlx::query(
        "SELECT b.id FROM builds b JOIN evalrepoints r USING (id)
         ORDER BY b.id FOR UPDATE OF b",
    )
    .execute(tx.raw())
    .await?;
    Ok(sqlx::query(
        "UPDATE builds SET drvpath = r.drvpath, finished = 0, buildstatus = NULL
         FROM evalrepoints r WHERE builds.id = r.id",
    )
    .execute(tx.raw())
    .await?
    .rows_affected())
}

/// Drop what [`stage_repoints`] kept, once [`repoint`] is done with it,
/// whether it succeeded or not. Nothing to drop is not an error.
pub(crate) async fn drop_repoints(conn: &mut db::Connection) -> Result<(), sqlx::Error> {
    sqlx::raw_sql("DROP TABLE IF EXISTS pg_temp.evalrepoints")
        .execute(conn.raw())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::nix_eval_jobs::Job;

    fn job(value: serde_json::Value) -> Job {
        serde_json::from_value(value).unwrap()
    }

    /// A connection to a fresh database, in the replica role, which skips
    /// the foreign keys so that no jobset is needed.
    async fn replica() -> (test_utils::TestPg, sqlx::PgPool, db::Connection) {
        let (pg, pool) = test_utils::TestPg::new().await;
        let db = db::Database::new(&pg.url(), 1).await.unwrap();
        let mut conn = db.get().await.unwrap();
        sqlx::query("SET session_replication_role = 'replica'")
            .execute(conn.raw())
            .await
            .unwrap();
        (pg, pool, conn)
    }

    #[tokio::test]
    async fn queue_new_writes_each_jobs_own_build_and_outputs() {
        type Row = (
            i32,
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

        let (_pg, _pool, mut conn) = replica().await;
        let jobs = [
            job(serde_json::json!({
                "attr": "a", "name": "a-1", "drvPath": "a1.drv", "system": "x86_64-linux",
                "outputs": {"out": "/nix/store/a1"},
                "meta": {
                    "description": "desc", "license": "mit", "homepage": "https://a",
                    "maintainers": "alice", "maxSilent": 10, "timeout": 20,
                    "schedulingPriority": 5, "isChannel": true,
                },
            })),
            // Same job, other derivation: a build of its own.
            // Content-addressed: no path yet.
            job(serde_json::json!({
                "attr": "a", "drvPath": "a2.drv", "system": "x86_64-linux",
                "outputs": {"out": null},
            })),
            job(serde_json::json!({
                "attr": "b", "drvPath": "b.drv", "system": "x86_64-linux",
                "outputs": {"dev": "/nix/store/b-dev", "out": "/nix/store/b"},
            })),
        ];
        let mut staged = super::Jobs::default();
        for (ord, job) in (0..).zip(&jobs) {
            let (name, path) = job.outputs.iter().next().unwrap();
            let drv = job.drv_path.as_deref().unwrap();
            staged.push(ord, job, drv, (name, path.as_deref()));
        }

        let mut tx = conn.begin_transaction().await.unwrap();
        super::stage(&mut tx, &staged).await.unwrap();
        super::queue_new(&mut tx, 1).await.unwrap();

        let rows: Vec<Row> = sqlx::query_as(
            "SELECT id, job, drvpath, nixname, description, license, homepage,
                    maintainers, maxsilent, timeout, priority, ischannel
             FROM builds ORDER BY id",
        )
        .fetch_all(tx.raw())
        .await
        .unwrap();
        let s = |s: &str| Some(s.to_owned());
        let none = |id: i32, job: &str, drv: &str| {
            let (job, drv) = (job.to_owned(), drv.to_owned());
            (
                id, job, drv, None, None, None, None, None, None, None, 100, 0,
            )
        };
        assert_eq!(
            rows,
            [
                (
                    1,
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
                none(2, "a", "a2.drv"),
                none(3, "b", "b.drv"),
            ]
        );

        let outputs: Vec<(i32, String, Option<String>)> =
            sqlx::query_as("SELECT build, name, path FROM buildoutputs ORDER BY build, name")
                .fetch_all(tx.raw())
                .await
                .unwrap();
        assert_eq!(
            outputs,
            [
                (1, "out".to_owned(), s("/nix/store/a1")),
                (2, "out".to_owned(), None),
                (3, "dev".to_owned(), s("/nix/store/b-dev")),
                (3, "out".to_owned(), s("/nix/store/b")),
            ]
        );
    }

    #[tokio::test]
    async fn repoint_requeues_each_build_with_its_own_drv() {
        let (_pg, pool, mut conn) = replica().await;
        sqlx::raw_sql(
            "INSERT INTO builds (id, finished, buildstatus, starttime, stoptime,
                                 timestamp, jobset_id, job, drvpath, system)
             SELECT id, 1, 0, 1, 1, 0, 1, 'job', 'old' || id || '.drv', 'x86_64-linux'
             FROM generate_series(1, 3) AS id;
             -- What `stage_repoints` would have kept, out of id order.
             CREATE TEMP TABLE evalrepoints AS
               SELECT * FROM (VALUES (3, 'new3.drv'), (1, 'new1.drv')) AS t(id, drvpath);",
        )
        .execute(conn.raw())
        .await
        .unwrap();

        let mut tx = conn.begin_transaction().await.unwrap();
        assert_eq!(super::repoint(&mut tx).await.unwrap(), 2);
        tx.commit().await.unwrap();
        super::drop_repoints(&mut conn).await.unwrap();

        let rows: Vec<(i32, String, i32, Option<i32>)> =
            sqlx::query_as("SELECT id, drvpath, finished, buildstatus FROM builds ORDER BY id")
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(
            rows,
            [
                (1, "new1.drv".to_owned(), 0, None),
                (2, "old2.drv".to_owned(), 1, Some(0)),
                (3, "new3.drv".to_owned(), 0, None),
            ]
        );
    }
}
