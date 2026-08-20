use std::future::Future;

use db::models::BuildID;

/// A build the daemon has been asked to perform, after the checks in
/// [`crate::handler`] have accepted it.
#[derive(Debug, Clone, Copy)]
pub struct BuildRequest<'a> {
    /// Absolute store path of the `.drv`, already verified to be present
    /// in the upstream store.
    pub drv_path: &'a str,
    /// Derivation name, used for the `Builds.job` / `Builds.nixname`
    /// columns.
    pub nix_name: &'a str,
    /// Platform the derivation asks for, or `""` when the request did not
    /// carry one (`BuildPaths` has no derivation to read it from).
    pub system: &'a str,
}

/// Decides which `Builds` row a daemon build request becomes.
///
/// The daemon protocol says nothing about Hydra's data model: a client
/// asks for a derivation to be realised and waits. Everything after that
/// — creating the row, waiting for the queue runner, reporting the
/// outputs back — is the same regardless of *why* the build was asked
/// for. This trait is the one part that isn't: a standalone daemon files
/// builds under an ad-hoc jobset, while an evaluator that hosts the
/// server itself knows the evaluation the build belongs to.
///
/// The implementation runs inside the transaction that the handler later
/// commits, so any rows it writes land atomically with the build itself.
/// It must not commit or roll back the transaction.
pub trait SubmitBuild: Clone + Send + Sync + 'static {
    /// Insert the `Builds` row for `request` and return its id.
    fn submit(
        &self,
        tx: &mut db::Transaction<'_>,
        request: BuildRequest<'_>,
    ) -> impl Future<Output = Result<BuildID, db::Error>> + Send;
}
