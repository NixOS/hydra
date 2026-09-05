use db::models::BuildID;

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
        let jobset_id = db.get().await?.ensure_adhoc_jobset().await?;
        Ok(Self { jobset_id })
    }

    /// Insert the `Builds` row for `request` and return its id.
    ///
    /// Runs inside the transaction that the handler later commits, so
    /// the row lands atomically with everything else the handler writes.
    pub(crate) async fn submit(
        &self,
        tx: &mut db::Transaction<'_>,
        request: BuildRequest<'_>,
    ) -> Result<BuildID, db::Error> {
        Ok(tx
            .insert_daemon_build(
                self.jobset_id,
                request.nix_name,
                request.drv_path,
                request.system,
            )
            .await?)
    }
}
