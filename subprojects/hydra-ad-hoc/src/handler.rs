use std::collections::{BTreeMap, BTreeSet};
use std::future::{Future, ready};
use std::path::Path;
use std::pin::Pin;

use tokio::io::AsyncBufRead;

use harmonia_protocol::daemon::{
    DaemonError as ProtocolError, DaemonResult, DaemonStore, FutureResultExt, HandshakeDaemonStore,
    ResultLog, ResultLogExt, TrustLevel,
};
use harmonia_protocol::daemon_wire::types2::{
    BuildMode, BuildResult, BuildResultFailure, BuildResultInner, BuildResultSuccess,
    FailureStatus, KeyedBuildResult, SuccessStatus,
};
use harmonia_protocol::types::AddToStoreItem;
use harmonia_protocol::valid_path_info::{UnkeyedValidPathInfo, ValidPathInfo};
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::BasicDerivation;
use harmonia_store_derivation::derived_path::{DerivedPath, OutputName, SingleDerivedPath};
use harmonia_store_derivation::realisation::UnkeyedRealisation;
use harmonia_store_path::{StorePath, StorePathHash, StorePathSet};
use harmonia_store_remote::pool::{ConnectionPool, PoolConfig};

use db::StoreDir;
use db::models::{BuildID, BuildStatus};
use sqlx::Connection as _;
use tokio::sync::{mpsc, oneshot, watch};

use crate::logs::{LogSource, build_log_stream};
use crate::queries::{FinishedBuild, get_finished_build};
use crate::submit::{AdhocSubmitter, BuildRequest};
use crate::waiter::BuildWaiter;

/// Daemon-store implementation that schedules build requests through Hydra.
///
/// Read operations and store uploads are proxied to an upstream
/// nix-daemon; build requests become Hydra `Builds` rows filed by
/// [`AdhocSubmitter`].
#[derive(Clone)]
pub(crate) struct HydraDaemonHandler {
    store_dir: StoreDir,
    db: db::Database,
    upstream: ConnectionPool,
    waiter: BuildWaiter,
    submitter: AdhocSubmitter,
    logs: LogSource,
}

impl std::fmt::Debug for HydraDaemonHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HydraDaemonHandler")
            .field("store_dir", &self.store_dir)
            .finish_non_exhaustive()
    }
}

impl HydraDaemonHandler {
    pub(crate) fn new(
        store_dir: StoreDir,
        db: db::Database,
        upstream_socket: &Path,
        waiter: BuildWaiter,
        submitter: AdhocSubmitter,
        logs: LogSource,
    ) -> Self {
        let upstream = ConnectionPool::with_store_dir(
            upstream_socket,
            store_dir.clone(),
            PoolConfig::default(),
        );
        Self {
            store_dir,
            db,
            upstream,
            waiter,
            submitter,
            logs,
        }
    }

    /// Reject build requests whose .drv is not present for the queue
    /// runner to read. `nix-store --realise` sends `BuildPaths` even for
    /// a path `QueryMissing` just called unknown, and a row for a .drv
    /// nobody has can only ever be aborted.
    async fn assert_drv_uploaded(&self, drv_path: &StorePath) -> Result<(), ProtocolError> {
        let mut guard = self
            .upstream
            .acquire()
            .await
            .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
        if !guard.execute(|c| c.is_valid_path(drv_path)).await? {
            return Err(ProtocolError::custom(format!(
                "hydra-ad-hoc: {} is not present in the upstream \
                 store; upload it via add_to_store_nar / \
                 add_multiple_to_store before requesting a build",
                self.store_dir.display(drv_path)
            )));
        }
        Ok(())
    }

    /// Output paths the queue runner recorded for successful build
    /// steps of `drv_path`.
    async fn built_outputs(
        &self,
        drv_path: &StorePath,
    ) -> Result<BTreeMap<OutputName, StorePath>, ProtocolError> {
        let mut conn = self
            .db
            .get()
            .await
            .map_err(|e| ProtocolError::custom(format!("hydra db: {e}")))?;
        let mut tx = conn
            .begin_transaction()
            .await
            .map_err(|e| ProtocolError::custom(format!("hydra db: {e}")))?;
        tx.find_build_step_outputs(&self.store_dir, drv_path)
            .await
            .map_err(|e| ProtocolError::custom(format!("build step outputs: {e}")))
    }

    /// The static `.drv` a derived path stands for.
    ///
    /// A dynamic derivation's `.drv` is itself the output of another
    /// derivation, and a `Builds` row can only name a `.drv` that exists.
    /// So walk in from the outside: build the innermost derivation, take
    /// the `.drv` it produced from its outputs, and repeat until the
    /// derivation the client asked for is on disk. The queue runner does
    /// the same for dynamic *inputs* of a build; this is the top level.
    fn resolve_drv<'a>(
        &'a self,
        path: &'a SingleDerivedPath,
        announce: &'a mpsc::UnboundedSender<BuildID>,
    ) -> Pin<Box<dyn Future<Output = Result<StorePath, ProtocolError>> + Send + 'a>> {
        Box::pin(async move {
            match path {
                SingleDerivedPath::Opaque(drv_path) => Ok(drv_path.clone()),
                SingleDerivedPath::Built { drv_path, output } => {
                    let inner = self.resolve_drv(drv_path, announce).await?;
                    self.assert_drv_uploaded(&inner).await?;
                    let inner_str = self.store_dir.display(&inner).to_string();
                    let finished = self
                        .run_build(&inner_str, inner.name().as_ref(), "", announce)
                        .await?;
                    if finished.status != BuildStatus::Success {
                        return Err(ProtocolError::custom(format!(
                            "build of {inner_str}, needed for its output '{output}', failed: {}",
                            build_status_message(finished.status)
                        )));
                    }
                    finished.outputs.get(output).cloned().ok_or_else(|| {
                        ProtocolError::custom(format!(
                            "{inner_str} has no output '{output}' on record"
                        ))
                    })
                }
            }
        })
    }

    /// File the build and wait for the queue runner to finish it.
    async fn run_build(
        &self,
        drv_path: &str,
        nix_name: &str,
        system: &str,
        announce: &mpsc::UnboundedSender<BuildID>,
    ) -> Result<FinishedBuild, ProtocolError> {
        tracing::debug!(drv_path, nix_name, system, "build requested");
        let (build_id, rx) = self
            .schedule_build(drv_path, nix_name, system, announce)
            .await?;

        tracing::info!(build_id, drv_path, "scheduled build, awaiting finish");

        // Keep waiter cleanup centralized for every pre-completion error path.
        let result: Result<FinishedBuild, ProtocolError> = async {
            if rx.await.is_err() {
                return Err(ProtocolError::custom(
                    "build_finished listener went unhealthy mid-flight; \
                     try again once the daemon reconnects",
                ));
            }

            let mut conn = self
                .db
                .get()
                .await
                .map_err(|e| ProtocolError::custom(format!("hydra db: {e}")))?;
            get_finished_build(conn.raw(), &self.store_dir, build_id)
                .await
                .map_err(|e| ProtocolError::custom(format!("read finished build: {e}")))?
                .ok_or_else(|| {
                    ProtocolError::custom(format!("build {build_id} woke but has no finished row"))
                })
        }
        .await;

        if result.is_err() {
            self.waiter.forget(build_id).await;
        }
        result
    }

    /// Run `work` while streaming the logs of every build it announces.
    ///
    /// The daemon protocol delivers an operation's log messages before
    /// its result, and harmonia drains the log stream completely before
    /// it polls the result future, so the work has to run on its own
    /// task: the stream follows it, and the result future merely
    /// collects what it produced. `work` gets a channel to announce
    /// the ids of the builds it files (see `run_build`); the stream
    /// subscribes to step events before `work` starts, so it cannot
    /// miss a step of a build it will be told about.
    fn with_live_logs<T, F, Fut>(&self, work: F) -> impl ResultLog<Output = DaemonResult<T>> + Send
    where
        T: Send + 'static,
        F: FnOnce(mpsc::UnboundedSender<BuildID>) -> Fut,
        Fut: Future<Output = DaemonResult<T>> + Send + 'static,
    {
        let events = self.waiter.step_events();
        let (announce_tx, announce_rx) = mpsc::unbounded_channel();
        let (done_tx, done_rx) = watch::channel(false);
        let (result_tx, result_rx) = oneshot::channel();
        let fut = work(announce_tx);
        tokio::spawn(async move {
            let result = fut.await;
            let _ = done_tx.send(true);
            let _ = result_tx.send(result);
        });
        let logs = build_log_stream(self.logs.clone(), events, announce_rx, done_rx);
        async move {
            result_rx.await.unwrap_or_else(|_| {
                Err(ProtocolError::custom(
                    "build task ended without reporting a result",
                ))
            })
        }
        .with_logs(logs)
    }

    /// Insert the `Builds` row and commit it, returning its id and the
    /// waiter channel that fires when the queue runner finishes it.
    ///
    /// The pool connection lives only as long as this function: the
    /// caller then waits on `rx`, which can take hours, and holding a
    /// connection across that wait would let a few in-flight (or
    /// abandoned) requests exhaust the pool and block everything after
    /// them.
    async fn schedule_build(
        &self,
        drv_path: &str,
        nix_name: &str,
        system: &str,
        announce: &mpsc::UnboundedSender<BuildID>,
    ) -> Result<(BuildID, oneshot::Receiver<()>), ProtocolError> {
        let mut conn = self
            .db
            .get()
            .await
            .map_err(|e| ProtocolError::custom(format!("hydra db: {e}")))?;
        let mut tx = conn
            .raw()
            .begin()
            .await
            .map_err(|e| ProtocolError::custom(format!("begin tx: {e}")))?;
        let build_id = self
            .submitter
            .submit(
                &mut tx,
                BuildRequest {
                    drv_path,
                    nix_name,
                    system,
                },
            )
            .await
            .map_err(|e| ProtocolError::custom(format!("submit build: {e}")))?;

        // Register before commit so the queue runner cannot finish the
        // row before anyone is listening for it.
        let rx = self
            .waiter
            .register(build_id)
            .await
            .map_err(|e| ProtocolError::custom(format!("cannot schedule build: {e}")))?;

        // Tell the log stream before the commit that makes the row
        // visible, so no step of this build can be announced first.
        let _ = announce.send(build_id);

        let committed: Result<(), ProtocolError> = async {
            // What the queue runner listens on to pick up new rows.
            sqlx::query!("SELECT pg_notify('builds_added', '?')")
                .execute(&mut *tx)
                .await
                .map_err(|e| ProtocolError::custom(format!("notify builds_added: {e}")))?;
            tx.commit()
                .await
                .map_err(|e| ProtocolError::custom(format!("commit: {e}")))
        }
        .await;
        if let Err(e) = committed {
            self.waiter.forget(build_id).await;
            return Err(e);
        }
        Ok((build_id, rx))
    }
}

fn require_normal_mode(mode: BuildMode) -> Result<(), ProtocolError> {
    if mode == BuildMode::Normal {
        Ok(())
    } else {
        Err(ProtocolError::custom(format!(
            "hydra-ad-hoc only supports BuildMode::Normal, got {mode:?}"
        )))
    }
}

fn finished_to_build_result(
    drv_path: &str,
    finished: &FinishedBuild,
) -> Result<BuildResult, ProtocolError> {
    let inner = match finished.status {
        BuildStatus::Success => BuildResultInner::Success(BuildResultSuccess {
            status: SuccessStatus::Built,
            built_outputs: synthesize_built_outputs(drv_path, &finished.outputs)?,
        }),
        status => BuildResultInner::Failure(BuildResultFailure {
            status: build_status_to_failure(status),
            error_msg: build_status_message(status).into(),
            is_non_deterministic: status == BuildStatus::NotDeterministic,
        }),
    };
    Ok(BuildResult {
        inner,
        times_built: 1,
        start_time: finished.start_time.unwrap_or(0),
        stop_time: finished.stop_time.unwrap_or(0),
        cpu_user: None,
        cpu_system: None,
    })
}

/// Synthesize realisations from recorded output paths; missing paths are queue-runner bugs.
///
/// The result is keyed by output name, so each entry only carries the
/// unkeyed half of the realisation — the `DrvOutput` key is implied by the
/// derivation being built.
fn synthesize_built_outputs(
    drv_path: &str,
    outputs: &BTreeMap<OutputName, StorePath>,
) -> Result<BTreeMap<OutputName, UnkeyedRealisation>, ProtocolError> {
    if outputs.is_empty() {
        return Err(ProtocolError::custom(format!(
            "build of {drv_path} succeeded but has no outputs on record"
        )));
    }
    let mut map = BTreeMap::new();
    for (name, out_path) in outputs {
        map.insert(
            name.clone(),
            UnkeyedRealisation {
                out_path: out_path.clone(),
                signatures: BTreeSet::new(),
            },
        );
    }
    Ok(map)
}

fn build_status_to_failure(status: BuildStatus) -> FailureStatus {
    match status {
        BuildStatus::Failed | BuildStatus::FailedWithOutput => FailureStatus::PermanentFailure,
        BuildStatus::DepFailed => FailureStatus::DependencyFailed,
        BuildStatus::TimedOut => FailureStatus::TimedOut,
        BuildStatus::CachedFailure => FailureStatus::CachedFailure,
        BuildStatus::LogLimitExceeded => FailureStatus::LogLimitExceeded,
        BuildStatus::NarSizeLimitExceeded => FailureStatus::OutputRejected,
        BuildStatus::NotDeterministic => FailureStatus::NotDeterministic,
        BuildStatus::Unsupported
        | BuildStatus::Aborted
        | BuildStatus::Cancelled
        | BuildStatus::Busy
        | BuildStatus::Resolved
        | BuildStatus::Success => FailureStatus::MiscFailure,
    }
}

fn build_status_message(status: BuildStatus) -> &'static str {
    match status {
        BuildStatus::Success => "succeeded",
        BuildStatus::Failed => "build failed",
        BuildStatus::DepFailed => "a dependency failed to build",
        BuildStatus::Aborted => "build was aborted",
        BuildStatus::Cancelled => "build was cancelled",
        BuildStatus::FailedWithOutput => "build failed (with output)",
        BuildStatus::TimedOut => "build timed out",
        BuildStatus::CachedFailure => "build previously failed (cached)",
        BuildStatus::Unsupported => "system not supported",
        BuildStatus::LogLimitExceeded => "log size limit exceeded",
        BuildStatus::NarSizeLimitExceeded => "NAR size limit exceeded",
        BuildStatus::NotDeterministic => "build is not deterministic",
        BuildStatus::Busy => "build is still in progress",
        BuildStatus::Resolved => "CA derivation resolved (transient state)",
    }
}

impl HandshakeDaemonStore for HydraDaemonHandler {
    type Store = Self;

    fn handshake(self) -> impl ResultLog<Output = DaemonResult<Self::Store>> + Send {
        ready(Ok(self)).empty_logs()
    }
}

impl DaemonStore for HydraDaemonHandler {
    fn trust_level(&self) -> Option<TrustLevel> {
        Some(TrustLevel::Trusted)
    }

    fn set_options<'a>(
        &'a mut self,
        _options: &'a harmonia_protocol::types::ClientOptions,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        // Client options are intentionally ignored; proxied reads use upstream's settings.
        ready(Ok(())).empty_logs()
    }

    fn build_derivation<'a>(
        &'a mut self,
        drv_path: &'a StorePath,
        drv: &'a BasicDerivation,
        mode: BuildMode,
    ) -> impl ResultLog<Output = DaemonResult<BuildResult>> + Send + 'a {
        let this = self.clone();
        let drv_path = drv_path.clone();
        let drv = drv.clone();
        self.with_live_logs(move |announce| async move {
            require_normal_mode(mode)?;
            this.assert_drv_uploaded(&drv_path).await?;
            let drv_path_str = this.store_dir.display(&drv_path).to_string();
            let nix_name: String = drv.name.to_string();
            let system = std::str::from_utf8(&drv.platform)
                .map_err(|e| ProtocolError::custom(format!("non-utf8 platform: {e}")))?;
            let finished = this
                .run_build(&drv_path_str, &nix_name, system, &announce)
                .await?;
            finished_to_build_result(&drv_path_str, &finished)
        })
    }

    fn build_paths<'a>(
        &'a mut self,
        drvs: &'a [DerivedPath],
        mode: BuildMode,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        let this = self.clone();
        let drvs = drvs.to_vec();
        self.with_live_logs(move |announce| async move {
            require_normal_mode(mode)?;
            for path in &drvs {
                let drv_path = match path {
                    DerivedPath::Built { drv_path, .. } => {
                        this.resolve_drv(drv_path, &announce).await?
                    }
                    DerivedPath::Opaque(_) => {
                        return Err(ProtocolError::custom(
                            "hydra-ad-hoc BuildPaths does not support opaque (already-built) paths",
                        ));
                    }
                };
                this.assert_drv_uploaded(&drv_path).await?;
                let drv_path_str = this.store_dir.display(&drv_path).to_string();
                let nix_name = drv_path.name().as_ref().to_owned();
                let finished = this
                    .run_build(&drv_path_str, &nix_name, "", &announce)
                    .await?;
                if finished.status != BuildStatus::Success {
                    return Err(ProtocolError::custom(format!(
                        "build of {drv_path_str} failed: {}",
                        build_status_message(finished.status)
                    )));
                }
            }
            Ok(())
        })
    }

    fn build_paths_with_results<'a>(
        &'a mut self,
        drvs: &'a [DerivedPath],
        mode: BuildMode,
    ) -> impl ResultLog<Output = DaemonResult<Vec<KeyedBuildResult>>> + Send + 'a {
        let this = self.clone();
        let drvs = drvs.to_vec();
        self.with_live_logs(move |announce| async move {
            require_normal_mode(mode)?;
            let mut results = Vec::with_capacity(drvs.len());
            for path in &drvs {
                let drv_path = match path {
                    DerivedPath::Built { drv_path, .. } => {
                        this.resolve_drv(drv_path, &announce).await?
                    }
                    DerivedPath::Opaque(_) => {
                        return Err(ProtocolError::custom(
                            "hydra-ad-hoc BuildPathsWithResults does not support opaque paths",
                        ));
                    }
                };
                this.assert_drv_uploaded(&drv_path).await?;
                let drv_path_str = this.store_dir.display(&drv_path).to_string();
                let nix_name = drv_path.name().as_ref().to_owned();
                let finished = this
                    .run_build(&drv_path_str, &nix_name, "", &announce)
                    .await?;
                let result = finished_to_build_result(&drv_path_str, &finished)?;
                results.push(KeyedBuildResult {
                    path: path.clone(),
                    result,
                });
            }
            Ok(results)
        })
    }

    fn is_valid_path<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<bool>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.is_valid_path(path)).await
        }
        .empty_logs()
    }

    fn query_valid_paths<'a>(
        &'a mut self,
        paths: &'a StorePathSet,
        substitute: bool,
    ) -> impl ResultLog<Output = DaemonResult<StorePathSet>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .execute(|c| c.query_valid_paths(paths, substitute))
                .await
        }
        .empty_logs()
    }

    fn query_path_info<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<Option<UnkeyedValidPathInfo>>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_path_info(path)).await
        }
        .empty_logs()
    }

    fn query_path_from_hash_part<'a>(
        &'a mut self,
        hash: &'a StorePathHash,
    ) -> impl ResultLog<Output = DaemonResult<Option<StorePath>>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_path_from_hash_part(hash)).await
        }
        .empty_logs()
    }

    /// The upstream store knows a derivation's static output paths. A
    /// content-addressed output's path is only known once it has been
    /// built, and the queue runner records it in `BuildStepOutputs`
    /// rather than registering it with the upstream store, so fill the
    /// gaps from there.
    fn query_derivation_output_map<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<BTreeMap<OutputName, Option<StorePath>>>> + Send + 'a
    {
        let this = self.clone();
        async move {
            let mut map = {
                let mut guard = this
                    .upstream
                    .acquire()
                    .await
                    .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
                guard
                    .execute(|c| c.query_derivation_output_map(path))
                    .await?
            };
            if map.values().any(Option::is_none) {
                let built = this.built_outputs(path).await?;
                for (name, slot) in &mut map {
                    if slot.is_none() {
                        *slot = built.get(name).cloned();
                    }
                }
            }
            Ok(map)
        }
        .empty_logs()
    }

    fn query_missing<'a>(
        &'a mut self,
        paths: &'a [DerivedPath],
    ) -> impl ResultLog<
        Output = DaemonResult<harmonia_protocol::daemon_wire::types2::QueryMissingResult>,
    > + Send
    + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_missing(paths)).await
        }
        .empty_logs()
    }

    fn query_referrers<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<StorePathSet>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_referrers(path)).await
        }
        .empty_logs()
    }

    fn query_substitutable_paths<'a>(
        &'a mut self,
        paths: &'a StorePathSet,
    ) -> impl ResultLog<Output = DaemonResult<StorePathSet>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_substitutable_paths(paths)).await
        }
        .empty_logs()
    }

    fn query_valid_derivers<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<StorePathSet>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.query_valid_derivers(path)).await
        }
        .empty_logs()
    }

    /// See `query_derivation_output_map`: a realisation the upstream
    /// store lacks may still be on record from a Hydra build.
    fn query_realisation<'a>(
        &'a mut self,
        output_id: &'a harmonia_store_derivation::realisation::DrvOutput,
    ) -> impl ResultLog<Output = DaemonResult<Option<UnkeyedRealisation>>> + Send + 'a {
        let this = self.clone();
        async move {
            let upstream = {
                let mut guard = this
                    .upstream
                    .acquire()
                    .await
                    .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
                guard.execute(|c| c.query_realisation(output_id)).await?
            };
            if upstream.is_some() {
                return Ok(upstream);
            }
            let built = this.built_outputs(&output_id.drv_path).await?;
            Ok(built
                .get(&output_id.output_name)
                .map(|out_path| UnkeyedRealisation {
                    out_path: out_path.clone(),
                    signatures: BTreeSet::new(),
                }))
        }
        .empty_logs()
    }

    fn add_temp_root<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        // Temp roots attach to the upstream pooled connection, so they may outlive this client.
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.add_temp_root(path)).await
        }
        .empty_logs()
    }

    fn ensure_path<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.ensure_path(path)).await
        }
        .empty_logs()
    }

    fn add_indirect_root<'a>(
        &'a mut self,
        path: &'a harmonia_protocol::types::DaemonPath,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.execute(|c| c.add_indirect_root(path)).await
        }
        .empty_logs()
    }

    fn add_perm_root<'a>(
        &'a mut self,
        store_path: &'a StorePath,
        gc_root: &'a harmonia_protocol::types::DaemonPath,
    ) -> impl ResultLog<Output = DaemonResult<harmonia_protocol::types::DaemonPath>> + Send + 'a
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .execute(|c| c.add_perm_root(store_path, gc_root))
                .await
        }
        .empty_logs()
    }

    fn add_ca_to_store<'a, 'r, R>(
        &'a mut self,
        name: &'a str,
        cam: ContentAddressMethodAlgorithm,
        refs: &'a StorePathSet,
        repair: bool,
        source: R,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<ValidPathInfo>> + Send + 'r>>
    where
        R: AsyncBufRead + Send + Unpin + 'r,
        'a: 'r,
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .execute(|c| c.add_ca_to_store(name, cam, refs, repair, source))
                .await
        }
        .empty_logs()
        .boxed_result()
    }

    fn add_multiple_to_store<'s, 'i, 'r, St, R>(
        &'s mut self,
        repair: bool,
        dont_check_sigs: bool,
        stream: St,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<()>> + Send + 'r>>
    where
        St: futures::Stream<Item = Result<AddToStoreItem<R>, ProtocolError>> + Send + 'i,
        R: AsyncBufRead + Send + Unpin + 'i,
        's: 'r,
        'i: 'r,
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .execute(|c| c.add_multiple_to_store(repair, dont_check_sigs, stream))
                .await
        }
        .empty_logs()
        .boxed_result()
    }

    fn add_to_store_nar<'s, 'r, 'i, R>(
        &'s mut self,
        info: &'i ValidPathInfo,
        source: R,
        repair: bool,
        dont_check_sigs: bool,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<()>> + Send + 'r>>
    where
        R: AsyncBufRead + Send + Unpin + 'r,
        's: 'r,
        'i: 'r,
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .execute(|c| c.add_to_store_nar(info, source, repair, dont_check_sigs))
                .await
        }
        .empty_logs()
        .boxed_result()
    }

    fn shutdown(&mut self) -> impl Future<Output = DaemonResult<()>> + Send + '_ {
        ready(Ok(()))
    }
}
