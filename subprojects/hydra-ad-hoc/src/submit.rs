//! Filing a daemon-submitted build in Hydra's database.
//!
//! The `db` crate owns the schema knowledge the whole of Hydra shares.
//! The hidden `adhoc/adhoc` jobset and the shape of a build filed
//! without an evaluation are this daemon's business alone, so their
//! queries live here, compile-time checked against the same schema,
//! on the raw connections `db` hands out for exactly this purpose.

use db::models::BuildID;
use sqlx::Connection as _;

/// A build the daemon has been asked to perform, after the checks in
/// [`crate::handler`] have accepted it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BuildRequest<'a> {
    /// Absolute store path of the `.drv`, already verified to be present
    /// in the upstream store.
    pub(crate) drv_path: &'a str,
    /// Derivation name, used for the `Builds.job` / `Builds.nixname`
    /// columns.
    pub(crate) nix_name: &'a str,
    /// Platform the derivation asks for, or `""` when the request did not
    /// carry one (`BuildPaths` has no derivation to read it from).
    pub(crate) system: &'a str,
}

/// Files every request under one hidden `adhoc/adhoc` jobset.
///
/// The daemon protocol says nothing about Hydra's data model: a client
/// asks for a derivation to be realised and waits, and tells us nothing
/// about why it wants it built. So there is no evaluation or job to
/// attribute the build to, but the rows still need *a* jobset to hang
/// off, hence the shared hidden one.
#[derive(Debug, Clone)]
pub(crate) struct AdhocSubmitter {
    jobset_id: i32,
}

impl AdhocSubmitter {
    /// Create the `adhoc/adhoc` jobset if it does not exist yet, and
    /// remember its id.
    ///
    /// Resolved once at startup rather than per build: the jobset is
    /// created on demand and never removed, so re-checking on every
    /// request would be a round trip to learn the same answer.
    pub(crate) async fn new(db: db::Database) -> Result<Self, db::Error> {
        let jobset_id = ensure_adhoc_jobset(db.get().await?.raw()).await?;
        Ok(Self { jobset_id })
    }

    /// Insert the `Builds` row for `request` and return its id.
    ///
    /// Runs inside the transaction that the handler later commits, so
    /// the row lands atomically with everything else the handler writes.
    /// The row is kept (`keep = 1`) so `hydra-update-gc-roots` retains
    /// its outputs, since no jobset evaluation will ever claim them.
    pub(crate) async fn submit(
        &self,
        tx: &mut sqlx::PgTransaction<'_>,
        request: BuildRequest<'_>,
    ) -> Result<BuildID, db::Error> {
        let id = sqlx::query_scalar!(
            "INSERT INTO Builds (
                finished, timestamp, jobset_id, job, nixname, drvPath, system,
                maxsilent, timeout, ischannel, iscurrent, priority, globalpriority, keep
             ) VALUES (
                0, EXTRACT(EPOCH FROM NOW())::INT4, $1, $2, $2, $3, $4,
                7200, 36000, 0, 0, 100, 0, 1
             ) RETURNING id",
            self.jobset_id,
            request.nix_name,
            request.drv_path,
            request.system,
        )
        .fetch_one(&mut **tx)
        .await?;
        Ok(id)
    }
}

/// Ensure the hidden jobset used for daemon-submitted builds exists,
/// along with the project and user it hangs off, and return its id.
async fn ensure_adhoc_jobset(conn: &mut sqlx::PgConnection) -> Result<i32, db::Error> {
    let mut tx = conn.begin().await?;

    sqlx::query!(
        "INSERT INTO Users (userName, fullName, emailAddress, password)
         VALUES ('adhoc', 'Ad-hoc', 'adhoc@localhost', '')
         ON CONFLICT (userName) DO NOTHING",
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "INSERT INTO Projects (name, displayName, description, owner, enabled, hidden)
         VALUES ('adhoc', 'Ad-hoc', 'Ad-hoc builds via hydra-ad-hoc', 'adhoc', 1, 1)
         ON CONFLICT (name) DO NOTHING",
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "INSERT INTO Jobsets
            (name, project, description, nixExprInput, nixExprPath, emailOverride, type, hidden)
         VALUES ('adhoc', 'adhoc', 'Ad-hoc builds via hydra-ad-hoc', '', '', '', 0, 1)
         ON CONFLICT (project, name) DO NOTHING",
    )
    .execute(&mut *tx)
    .await?;

    let id =
        sqlx::query_scalar!("SELECT id FROM Jobsets WHERE project = 'adhoc' AND name = 'adhoc'")
            .fetch_one(&mut *tx)
            .await?;

    tx.commit().await?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn setup() -> (test_utils::TestPg, db::Database) {
        let (pg, _pool) = test_utils::TestPg::new().await;
        let db = db::Database::new(&pg.url(), 2).await.unwrap();
        (pg, db)
    }

    #[tokio::test]
    async fn ensure_adhoc_jobset_is_idempotent() {
        let (_pg, db) = setup().await;
        let id1 = AdhocSubmitter::new(db.clone()).await.unwrap().jobset_id;
        let id2 = AdhocSubmitter::new(db).await.unwrap().jobset_id;
        assert_eq!(id1, id2);
    }

    #[tokio::test]
    async fn submit_sets_keep_and_starts_unfinished() {
        let (_pg, db) = setup().await;
        let submitter = AdhocSubmitter::new(db.clone()).await.unwrap();
        let mut conn = db.get().await.unwrap();
        let mut tx = conn.raw().begin().await.unwrap();
        let build_id = submitter
            .submit(
                &mut tx,
                BuildRequest {
                    drv_path: "/nix/store/foo.drv",
                    nix_name: "hello",
                    system: "x86_64-linux",
                },
            )
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let row = sqlx::query!(
            "SELECT keep, finished, drvPath, system FROM Builds WHERE id = $1",
            build_id
        )
        .fetch_one(conn.raw())
        .await
        .unwrap();
        assert_eq!(
            row.keep, 1,
            "keep=1 so hydra-update-gc-roots retains outputs"
        );
        assert_eq!(row.finished, 0, "build starts unfinished");
        assert_eq!(row.drvpath, "/nix/store/foo.drv");
        assert_eq!(row.system, "x86_64-linux");
    }
}
