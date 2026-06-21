use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Instant;

use color_eyre::eyre::{self, WrapErr as _};
use futures::TryFutureExt as _;
use harmonia_protocol::daemon_wire::types2::BuildResultSuccess;
use harmonia_store_remote::DaemonStore as _;
use hashbrown::HashMap;

use crate::error::BuilderError;
use crate::grpc::BuilderClient;
use crate::types::BuildTimings;
use binary_cache::{
    CacheError, Compression, MorePartsSource, PresignedPart, PresignedUpload, PresignedUploadClient,
};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::StorePath;
use hydra_proto::ProtoStorePath;
use hydra_proto::{
    AbortMessage, BuildMessage, BuildResultInfo, BuildResultState, JoinMessage, OutputInfo,
    PingMessage, StepStatus, StepUpdate,
};
use local_nix_db::LocalNixDb;
#[derive(thiserror::Error, Debug)]
pub enum JobFailure {
    #[error("Build failure")]
    Build(#[source] eyre::Report),
    #[error("Build timed out")]
    TimedOut(#[source] eyre::Report),
    #[error("Build log limit exceeded")]
    LogLimit(#[source] eyre::Report),
    #[error("Output size limit exceeded")]
    OutputLimit(#[source] eyre::Report),
    #[error("Preparing failure")]
    Preparing(#[source] eyre::Report),
    #[error("Import failure")]
    Import(#[source] eyre::Report),
    #[error("Upload failure")]
    Upload(#[source] eyre::Report),
    #[error("Post processing failure")]
    PostProcessing(#[source] eyre::Report),
}

impl From<eyre::Report> for JobFailure {
    fn from(e: eyre::Report) -> Self {
        Self::Build(e)
    }
}

impl From<&JobFailure> for BuildResultState {
    fn from(item: &JobFailure) -> Self {
        match item {
            JobFailure::Build(_) => Self::BuildFailure,
            JobFailure::TimedOut(_) => Self::TimedOutFailure,
            JobFailure::LogLimit(_) => Self::LogLimitFailure,
            JobFailure::OutputLimit(_) => Self::NarSizeLimitFailure,
            JobFailure::Preparing(_) => Self::PreparingFailure,
            JobFailure::Import(_) => Self::ImportFailure,
            JobFailure::Upload(_) => Self::UploadFailure,
            JobFailure::PostProcessing(_) => Self::PostProcessingFailure,
        }
    }
}

#[derive(Debug)]
pub struct BuildInfo {
    drv_path: StorePath,
    handle: tokio::task::JoinHandle<()>,
    was_cancelled: Arc<AtomicBool>,
}

impl BuildInfo {
    fn abort(&self) {
        self.was_cancelled.store(true, Ordering::SeqCst);
        self.handle.abort();
    }
}

#[derive(Debug)]
pub struct Config {
    pub ping_interval: u64,
    pub speed_factor: f32,
    pub max_jobs: u32,
    pub build_cores: u32,
    pub build_dir_avail_threshold: f32,
    pub store_avail_threshold: f32,
    pub load1_threshold: f32,
    pub cpu_psi_threshold: f32,
    pub mem_psi_threshold: f32,
    pub io_psi_threshold: Option<f32>,
    pub gcroots: std::path::PathBuf,
    pub systems: Vec<String>,
    pub supported_features: Vec<String>,
    pub mandatory_features: Vec<String>,
    pub cgroups: bool,
    pub use_substitutes: bool,
    pub substituters: Vec<String>,
    pub nix_version: String,
    pub build_dir: String,
    pub store_dir: harmonia_store_path::StoreDir,
    /// Physical store directory on disk (for chroot stores).
    /// `None` means the logical store dir is the filesystem path.
    pub real_store_dir: Option<std::path::PathBuf>,
}

#[allow(missing_debug_implementations)]
pub struct State {
    pub id: uuid::Uuid,
    pub hostname: String,
    pub config: Config,
    pub max_concurrent_downloads: AtomicU32,
    pub connector: daemon_client_utils::DaemonConnector,
    /// Read-only handle to the local Nix store `SQLite` database. Validity
    /// and path-info reads go here rather than through the daemon, so they
    /// neither contend with NAR transfers for pooled connections nor risk
    /// reading a connection a cancelled transfer left desynced.
    pub local_db: LocalNixDb,

    active_builds: parking_lot::RwLock<HashMap<uuid::Uuid, Arc<BuildInfo>>>,
    pub client: BuilderClient,
    pub halt: AtomicBool,
    pub metrics: Arc<crate::metrics::Metrics>,
    upload_client: PresignedUploadClient,
    /// Budget of NARs uploaded concurrently across all builds. Shared rather
    /// than per-build because a single build rarely has enough new paths to
    /// keep the link busy.
    nar_upload_semaphore: Arc<tokio::sync::Semaphore>,
}

#[derive(Debug)]
struct Gcroot {
    root: std::path::PathBuf,
}

impl Gcroot {
    pub(crate) fn new(path: std::path::PathBuf) -> std::io::Result<Self> {
        fs_err::create_dir_all(&path)?;
        Ok(Self { root: path })
    }
}

impl std::fmt::Display for Gcroot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        write!(f, "{}", self.root.display())
    }
}

impl Drop for Gcroot {
    fn drop(&mut self) {
        if self.root.exists() {
            let _ = fs_err::remove_dir_all(&self.root);
        }
    }
}

impl State {
    #[tracing::instrument(err)]
    pub async fn new(cli: &super::config::Cli) -> Result<Arc<Self>, BuilderError> {
        let nix_config =
            crate::nix_config::NixConfig::load().map_err(BuilderError::LoadNixConfig)?;
        let nix_remote =
            daemon_client_utils::parse_nix_remote().map_err(BuilderError::ParseNixStore)?;

        let logname =
            std::env::var("LOGNAME").map_err(|_| BuilderError::MissingEnvVar("LOGNAME"))?;
        let gcroots = nix_remote
            .state_dir
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots/builder");
        fs_err::tokio::create_dir_all(&gcroots)
            .await
            .map_err(BuilderError::CreateGcroots)?;

        let connector = daemon_client_utils::DaemonConnector::new(
            nix_remote.socket.clone(),
            nix_remote.store_dir.clone(),
        );

        let db_path = nix_remote.state_dir.join("db/db.sqlite");
        let local_db = LocalNixDb::open_at(nix_remote.store_dir.clone(), &db_path)
            .await
            .map_err(|e| BuilderError::OpenLocalNixDb(db_path, e))?;

        let state = Arc::new(Self {
            id: uuid::Uuid::new_v4(),
            hostname: gethostname::gethostname()
                .into_string()
                .map_err(BuilderError::Hostname)?,
            active_builds: parking_lot::RwLock::new(HashMap::with_capacity(10)),
            config: Config {
                ping_interval: cli.ping_interval,
                speed_factor: cli.speed_factor,
                max_jobs: cli.max_jobs,
                build_cores: cli.build_cores,
                build_dir_avail_threshold: cli.build_dir_avail_threshold,
                store_avail_threshold: cli.store_avail_threshold,
                load1_threshold: cli.load1_threshold,
                cpu_psi_threshold: cli.cpu_psi_threshold,
                mem_psi_threshold: cli.mem_psi_threshold,
                io_psi_threshold: cli.io_psi_threshold,
                gcroots,
                systems: cli.systems.as_ref().map_or_else(
                    || {
                        let mut out = Vec::with_capacity(8);
                        out.push(nix_config.system());
                        out.extend(nix_config.extra_platforms());
                        out
                    },
                    Clone::clone,
                ),
                supported_features: cli
                    .supported_features
                    .as_ref()
                    .map_or_else(|| nix_config.system_features(), Clone::clone),
                mandatory_features: cli.mandatory_features.clone().unwrap_or_default(),
                cgroups: nix_config.use_cgroups(),
                use_substitutes: cli.use_substitutes,
                substituters: nix_config.substituters(),
                nix_version: nix_config.nix_version(),
                build_dir: nix_config.build_dir(),
                store_dir: nix_remote.store_dir.clone(),
                real_store_dir: nix_remote.real_store_dir(),
            },
            connector,
            local_db,
            max_concurrent_downloads: 5.into(),
            client: crate::grpc::init_client(cli).await?,
            halt: false.into(),
            metrics: Arc::new(crate::metrics::Metrics::default()),
            upload_client: PresignedUploadClient::new(),
            nar_upload_semaphore: Arc::new(tokio::sync::Semaphore::new(
                GLOBAL_NAR_UPLOAD_CONCURRENCY,
            )),
        });
        tracing::info!("Builder systems={:?}", state.config.systems);
        tracing::info!(
            "Builder supported_features={:?}",
            state.config.supported_features
        );
        tracing::info!(
            "Builder mandatory_features={:?}",
            state.config.mandatory_features
        );
        tracing::info!("Builder use_cgroups={:?}", state.config.cgroups);

        Ok(state)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_join_message(&self) -> eyre::Result<JoinMessage> {
        let sys = crate::system::BaseSystemInfo::new()?;

        Ok(JoinMessage {
            machine_id: self.id.to_string(),
            systems: self.config.systems.clone(),
            hostname: self.hostname.clone(),
            cpu_count: u32::try_from(sys.cpu_count)?,
            bogomips: sys.bogomips,
            speed_factor: self.config.speed_factor,
            max_jobs: self.config.max_jobs,
            build_dir_avail_threshold: self.config.build_dir_avail_threshold,
            store_avail_threshold: self.config.store_avail_threshold,
            load1_threshold: self.config.load1_threshold,
            cpu_psi_threshold: self.config.cpu_psi_threshold,
            mem_psi_threshold: self.config.mem_psi_threshold,
            io_psi_threshold: self.config.io_psi_threshold,
            total_mem: sys.total_memory,
            supported_features: self.config.supported_features.clone(),
            mandatory_features: self.config.mandatory_features.clone(),
            cgroups: self.config.cgroups,
            substituters: self.config.substituters.clone(),
            use_substitutes: self.config.use_substitutes,
            nix_version: self.config.nix_version.clone(),
        })
    }

    #[tracing::instrument(skip(self), err)]
    pub fn get_ping_message(&self) -> eyre::Result<PingMessage> {
        let default_store = self.config.store_dir.to_string();
        let store_path = self
            .config
            .real_store_dir
            .as_ref()
            .map_or(default_store.as_str(), |p| {
                p.to_str().unwrap_or(default_store.as_str())
            });
        let sysinfo = crate::system::SystemLoad::new(&self.config.build_dir, store_path)?;

        Ok(PingMessage {
            machine_id: self.id.to_string(),
            load1: sysinfo.load_avg_1,
            load5: sysinfo.load_avg_5,
            load15: sysinfo.load_avg_15,
            mem_usage: sysinfo.mem_usage,
            pressure: sysinfo.pressure,
            build_dir_free_percent: sysinfo.build_dir_free_percent,
            store_free_percent: sysinfo.store_free_percent,
            current_substituting_path_count: self.metrics.get_substituting_path_count(),
            current_uploading_path_count: self.metrics.get_uploading_path_count(),
            current_downloading_path_count: self.metrics.get_downloading_path_count(),
        })
    }

    #[tracing::instrument(skip(self, m), fields(drv=?m.drv))]
    pub fn schedule_build(self: Arc<Self>, m: BuildMessage) -> eyre::Result<()> {
        if self.halt.load(Ordering::SeqCst) {
            tracing::warn!("State is set to halt, will no longer accept new builds!");
            return Err(eyre::eyre!("State set to halt."));
        }

        let drv = m.drv.clone().ok_or_else(|| eyre::eyre!("missing drv"))?.0;
        if self.contains_build(&drv) {
            return Ok(());
        }
        tracing::info!("Building {drv}");
        let build_id = uuid::Uuid::parse_str(&m.build_id)?;

        let was_cancelled = Arc::new(AtomicBool::new(false));
        let task_handle = tokio::spawn({
            let self_ = self.clone();
            let drv = drv.clone();
            let was_cancelled = was_cancelled.clone();
            async move {
                let mut timings = BuildTimings::default();
                match Box::pin(self_.process_build(m, &mut timings)).await {
                    Ok(()) => {
                        tracing::info!("Successfully completed build process for {drv}");
                        self_.remove_build(build_id);
                    }
                    Err(e) => {
                        if was_cancelled.load(Ordering::SeqCst) {
                            tracing::error!(
                                "Build of {drv} was cancelled, not reporting error: {}",
                                format_failure(&e)
                            );
                            return;
                        }

                        let result_state = BuildResultState::from(&e) as i32;
                        // Report the reason so it reaches the queue runner, not
                        // just this builder's journal.
                        let error_msg = format_failure(&e);

                        tracing::error!("Build of {drv} failed with: {error_msg}");
                        self_.remove_build(build_id);
                        let failed_build = BuildResultInfo {
                            build_id: build_id.to_string(),
                            machine_id: self_.id.to_string(),
                            import_time_ms: u64::try_from(timings.import_elapsed.as_millis())
                                .unwrap_or_default(),
                            build_time_ms: u64::try_from(timings.build_elapsed.as_millis())
                                .unwrap_or_default(),
                            upload_time_ms: u64::try_from(timings.upload_elapsed.as_millis())
                                .unwrap_or_default(),
                            result_state,
                            output_infos: std::collections::HashMap::new(),
                            error_msg: Some(error_msg),
                        };

                        if let Err(e) = self_.client.complete_build(failed_build).await {
                            tracing::error!("Failed to submit build failure info: {e}");
                        }
                    }
                }
            }
        });

        self.insert_new_build(
            build_id,
            BuildInfo {
                drv_path: drv,
                handle: task_handle,
                was_cancelled,
            },
        );
        Ok(())
    }

    fn contains_build(&self, drv: &StorePath) -> bool {
        let active = self.active_builds.read();
        active.values().any(|b| b.drv_path == *drv)
    }

    fn insert_new_build(&self, build_id: uuid::Uuid, b: BuildInfo) {
        {
            let mut active = self.active_builds.write();
            active.insert(build_id, Arc::new(b));
        }
        self.publish_builds_to_sd_notify();
    }

    fn remove_build(&self, build_id: uuid::Uuid) -> Option<Arc<BuildInfo>> {
        let b = {
            let mut active = self.active_builds.write();
            active.remove(&build_id)
        };
        self.publish_builds_to_sd_notify();
        b
    }

    #[tracing::instrument(skip(self, m), fields(build_id=%m.build_id))]
    pub fn abort_build(&self, m: &AbortMessage) -> eyre::Result<()> {
        tracing::info!("Try cancelling build");
        let build_id = uuid::Uuid::parse_str(&m.build_id)?;
        if let Some(b) = self.remove_build(build_id) {
            b.abort();
        }
        Ok(())
    }

    pub fn abort_all_active_builds(&self) {
        let mut active = self.active_builds.write();
        for b in active.values() {
            b.abort();
        }
        active.clear();
    }

    #[tracing::instrument(skip(self, connector, basic_drv))]
    async fn request_build(
        &self,
        connector: &daemon_client_utils::DaemonConnector,
        drv: &StorePath,
        basic_drv: &harmonia_store_derivation::derivation::BasicDerivation,
        options: harmonia_protocol::types::ClientOptions,
    ) -> Result<BuildResultSuccess, JobFailure> {
        // Build the pre-resolved BasicDerivation; logs stream to the queue-runner.
        let mut conn = connector
            .connect()
            .await
            .wrap_err("daemon connection failed")?;

        let (log_tx, log_rx) = tokio::sync::mpsc::unbounded_channel::<bytes::Bytes>();
        let log_stream = crate::utils::compressed_log_stream(drv, log_rx);
        let log_handle = tokio::spawn({
            let mut client = self.client.clone();
            async move { client.build_log(log_stream).await }
        });

        let build_result = {
            use futures::stream::StreamExt as _;

            // build_derivation does not take options; they must be
            // set per-client with a separate call.
            conn.set_options(&options)
                .await
                .map_err(|e| JobFailure::Build(e.into()))?;

            let mut result_log =
                std::pin::pin!(harmonia_protocol::types::DaemonStore::build_derivation(
                    &mut conn,
                    drv,
                    basic_drv,
                    harmonia_protocol::daemon_wire::types2::BuildMode::Normal,
                ));
            let send_line = |bytes: &[u8]| {
                let mut line = Vec::with_capacity(bytes.len() + 1);
                line.extend_from_slice(bytes);
                line.push(b'\n');
                let _ = log_tx.send(line.into());
            };
            while let Some(msg) = result_log.as_mut().next().await {
                use harmonia_protocol::log::{Field, LogMessage, ResultType};
                match msg {
                    LogMessage::Message(m) => {
                        send_line(&m.text);
                    }
                    LogMessage::Result(r)
                        if matches!(
                            r.result_type,
                            ResultType::BuildLogLine | ResultType::PostBuildLogLine
                        ) =>
                    {
                        for field in &r.fields {
                            if let Field::String(bytes) = field {
                                send_line(bytes);
                            }
                        }
                    }
                    _ => {}
                }
            }
            drop(log_tx);
            result_log.await.wrap_err("build_derivation failed")?
        };
        drop(conn);

        // Wait for the log stream to finish.  The build_log RPC
        // streams to the queue-runner and only resolves once the
        // channel is closed (i.e. the build finished).  A transport
        // error here (e.g. nginx sending an HTTP/2 GOAWAY after
        // hitting keepalive_requests) says nothing about whether the
        // derivation built, so it is non-fatal.
        if let Err(e) = log_handle.await {
            tracing::warn!("build log shipping failed for {drv}: {e}");
        }

        // Check for build failure.
        use harmonia_protocol::daemon_wire::types2::{BuildResultInner, FailureStatus};
        Ok(match build_result.inner {
            BuildResultInner::Success(s) => s,
            BuildResultInner::Failure(f) => {
                let report = eyre::eyre!("{}", build_failure_message(&f));
                // Preserve the daemon's failure status where the database
                // distinguishes it; everything else is a plain build failure.
                return Err(match f.status {
                    FailureStatus::TimedOut => JobFailure::TimedOut(report),
                    FailureStatus::LogLimitExceeded => JobFailure::LogLimit(report),
                    _ => JobFailure::Build(report),
                });
            }
        })
    }

    #[tracing::instrument(skip(self, m), fields(drv=?m.drv), err)]
    #[allow(clippy::too_many_lines)]
    async fn process_build(
        &self,
        m: BuildMessage,
        timings: &mut BuildTimings,
    ) -> Result<(), JobFailure> {
        let machine_id = self.id;
        let drv = m
            .drv
            .ok_or(JobFailure::Preparing(eyre::eyre!("missing drv")))?
            .0;

        let before_import = Instant::now();
        let gcroot_prefix = uuid::Uuid::new_v4().to_string();
        let gcroot = self
            .get_gcroot(&gcroot_prefix)
            .map_err(|e| JobFailure::Preparing(e.into()))?;

        let mut client = self.client.clone();
        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::SeningInputs as i32,
            })
            .await;

        // Decode the force-resolved BasicDerivation sent by the queue runner.
        let basic_drv: harmonia_store_derivation::derivation::BasicDerivation = m
            .resolved_drv
            .ok_or(JobFailure::Preparing(eyre::eyre!(
                "missing resolved_drv in BuildMessage",
            )))?
            .try_into()
            .map_err(|e: String| {
                JobFailure::Import(eyre::eyre!("failed to decode resolved derivation: {e}"))
            })?;

        // Fetch the transitive closure of the resolved inputs.
        let requisites = client
            .fetch_requisites(hydra_proto::StorePaths {
                paths: basic_drv.inputs.iter().map(ProtoStorePath::from).collect(),
            })
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .into_inner()
            .requisites;

        import_requisites(
            &mut client,
            &self.local_db,
            self.connector.clone(),
            self.metrics.clone(),
            &gcroot,
            &drv,
            requisites.into_iter().map(|s| s.0),
            usize::try_from(self.max_concurrent_downloads.load(Ordering::Relaxed)).unwrap_or(5),
            self.config.use_substitutes,
        )
        .await
        .map_err(JobFailure::Import)?;
        timings.import_elapsed = before_import.elapsed();

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::Building as i32,
            })
            .await;
        let before_build = Instant::now();

        let options = build_client_options(
            self.config.build_cores,
            m.max_silent_time,
            m.max_log_size,
            m.build_timeout,
            m.presigned_url_opts.is_some(),
        );

        let success = self
            .request_build(&self.connector, &drv, &basic_drv, options)
            .await?;

        // Extract output paths from the build result.
        let outputs: BTreeMap<OutputName, StorePath> = success
            .built_outputs
            .into_iter()
            .map(|(name, realisation)| (name, realisation.out_path))
            .collect();

        for o in outputs.values() {
            add_gc_root(&gcroot.root, self.connector.store_dir(), o);
        }

        timings.build_elapsed = before_build.elapsed();
        tracing::info!("Finished building {drv}");

        // Query path info for each output up front — these are needed both
        // for building the result message and are expected to exist for a
        // successful build.
        let mut output_infos = BTreeMap::new();
        for (name, path) in &outputs {
            let info = self
                .local_db
                .query_path_info(path)
                .await
                .wrap_err("query_path_info failed")
                .map_err(JobFailure::PostProcessing)?
                .ok_or_else(|| {
                    JobFailure::PostProcessing(eyre::eyre!("missing path info for output `{name}`"))
                })?;
            output_infos.insert(name.clone(), info);
        }

        // Enforce the per-output NAR size limit before uploading anything.
        if m.max_output_size > 0 {
            for (name, vpi) in &output_infos {
                if vpi.info.nar_size > m.max_output_size {
                    return Err(JobFailure::OutputLimit(eyre::eyre!(
                        "output `{name}` NAR size {} exceeds limit {}",
                        vpi.info.nar_size,
                        m.max_output_size,
                    )));
                }
            }
        }

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::ReceivingOutputs as i32,
            })
            .await;

        let before_upload = Instant::now();
        self.upload_nars(
            self.connector.clone(),
            outputs.values().cloned().collect::<Vec<_>>(),
            &m.build_id,
            &machine_id.to_string(),
            m.presigned_url_opts,
        )
        .await
        .map_err(JobFailure::Upload)?;
        timings.upload_elapsed = before_upload.elapsed();

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::PostProcessing as i32,
            })
            .await;
        let build_results = Box::pin(new_success_build_result_info(
            &self.local_db,
            self.connector.clone(),
            machine_id,
            &drv,
            &output_infos,
            *timings,
            m.build_id.clone(),
        ))
        .await
        .map_err(JobFailure::PostProcessing)?;

        client.complete_build(build_results).await.map_err(|e| {
            tracing::error!("Failed to submit build success info. Will fail build: err={e}");
            JobFailure::PostProcessing(e.into())
        })?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    fn get_gcroot(&self, prefix: &str) -> std::io::Result<Gcroot> {
        Gcroot::new(self.config.gcroots.join(prefix))
    }

    #[tracing::instrument(skip(self))]
    fn publish_builds_to_sd_notify(&self) {
        let active = {
            let builds = self.active_builds.read();
            builds
                .values()
                .map(|b| b.drv_path.to_string().clone())
                .collect::<Vec<_>>()
        };

        let _notify = sd_notify::notify(&[
            sd_notify::NotifyState::Status(&if active.is_empty() {
                "Building 0 drvs".into()
            } else {
                format!("Building {} drvs: {}", active.len(), active.join(", "))
            }),
            sd_notify::NotifyState::Ready,
        ]);
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_gcroots(&self) -> std::io::Result<()> {
        fs_err::tokio::remove_dir_all(&self.config.gcroots).await?;
        fs_err::tokio::create_dir_all(&self.config.gcroots).await?;
        Ok(())
    }

    pub fn enable_halt(&self) {
        self.halt.store(true, Ordering::SeqCst);
    }

    #[tracing::instrument(skip(self, connector, nars), err)]
    async fn upload_nars(
        &self,
        connector: daemon_client_utils::DaemonConnector,
        nars: Vec<StorePath>,
        build_id: &str,
        machine_id: &str,
        presigned_url_opts: Option<hydra_proto::PresignedUploadOpts>,
    ) -> eyre::Result<()> {
        if let Some(opts) = presigned_url_opts {
            upload_nars_presigned(
                self.client.clone(),
                &self.local_db,
                self.upload_client.clone(),
                connector,
                &nars,
                opts,
                build_id,
                machine_id,
                &self.nar_upload_semaphore,
            )
            .await
        } else {
            upload_nars_regular(
                self.client.clone(),
                &self.local_db,
                connector,
                self.metrics.clone(),
                nars,
            )
            .await
        }
    }
}

#[tracing::instrument(skip(local_db, connector), fields(%gcroot, %path))]
async fn is_path_missing(
    local_db: &LocalNixDb,
    connector: &daemon_client_utils::DaemonConnector,
    gcroot: &Gcroot,
    path: StorePath,
) -> eyre::Result<Option<StorePath>> {
    if local_db.is_valid_path(&path).await? {
        add_gc_root(&gcroot.root, connector.store_dir(), &path);
        Ok(None)
    } else {
        Ok(Some(path))
    }
}

/// Keep only paths not yet present in the local store.
async fn filter_missing(
    local_db: &LocalNixDb,
    connector: &daemon_client_utils::DaemonConnector,
    gcroot: &Gcroot,
    paths: Vec<StorePath>,
    concurrency: usize,
) -> eyre::Result<Vec<StorePath>> {
    use futures::StreamExt as _;
    futures::StreamExt::map(tokio_stream::iter(paths), |p| {
        is_path_missing(local_db, connector, gcroot, p)
    })
    .buffered(concurrency)
    .collect::<Vec<_>>()
    .await
    .into_iter()
    .collect::<eyre::Result<Vec<_>>>()
    .map(|v| v.into_iter().flatten().collect())
}

/// Create a GC root symlink for a store path.
///
/// The symlink target uses the logical store dir, which may dangle
/// outside a chroot but is correct inside it.
fn add_gc_root(
    gcroot_dir: &std::path::Path,
    store_dir: &harmonia_store_path::StoreDir,
    path: &StorePath,
) {
    let link = gcroot_dir.join(path.to_string());
    let target = store_dir.display(path).to_string();
    let _ = fs_err::os::unix::fs::symlink(target, &link);
}

/// Render a build failure for the journal and the queue runner: `{:#}` gives
/// the eyre cause chain without the `{:?}` backtrace, and `strip_ansi` drops
/// the colour codes the nix daemon bakes into build error messages. The
/// category is recorded separately as a `BuildResultState`, so we render the
/// inner cause chain only, omitting the redundant `JobFailure` label.
fn format_failure(e: &JobFailure) -> String {
    let report = match e {
        JobFailure::Build(r)
        | JobFailure::TimedOut(r)
        | JobFailure::LogLimit(r)
        | JobFailure::OutputLimit(r)
        | JobFailure::Preparing(r)
        | JobFailure::Import(r)
        | JobFailure::Upload(r)
        | JobFailure::PostProcessing(r) => r,
    };
    strip_ansi(&format!("{report:#}"))
}

/// Build the failure message for a derivation: the daemon's own message, or the
/// bare status when it is empty.
fn build_failure_message(
    f: &harmonia_protocol::daemon_wire::types2::BuildResultFailure,
) -> String {
    let error_msg = str::from_utf8(&f.error_msg).unwrap_or("Invalid UTF-8");
    if error_msg.trim().is_empty() {
        format!("build failed: {:?}", f.status)
    } else {
        error_msg.to_string()
    }
}

/// Remove the escape sequences nix emits in log and error output, matching the
/// forms handled by nix's `filterANSIEscapes`: CSI (`ESC [ ... final`), OSC
/// (`ESC ] ... ST|BEL`, e.g. hyperlinks) and other two-byte `ESC` sequences,
/// plus stray carriage returns and bells.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.peek() {
                // CSI: parameter/intermediate bytes then a final byte (0x40-0x7e).
                Some('[') => {
                    chars.next();
                    for c in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC: runs until ST (`ESC \`) or BEL.
                Some(']') => {
                    chars.next();
                    while let Some(c) = chars.next() {
                        if c == '\u{07}' {
                            break;
                        }
                        if c == '\u{1b}' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                // Other two-byte escape (e.g. `ESC c`): drop the following byte.
                Some(_) => {
                    chars.next();
                }
                None => {}
            },
            '\u{07}' | '\r' => {}
            _ => out.push(c),
        }
    }
    out
}

async fn substitute_paths(
    connector: &daemon_client_utils::DaemonConnector,
    paths: &[StorePath],
) -> eyre::Result<()> {
    let mut conn = connector.connect().await?;
    for p in paths {
        daemon_client_utils::ensure_path(&mut conn, p).await?;
    }
    Ok(())
}

#[tracing::instrument(skip(client, local_db, connector, metrics), fields(%gcroot), err)]
#[allow(clippy::too_many_arguments)]
async fn import_paths(
    mut client: BuilderClient,
    local_db: &LocalNixDb,
    connector: daemon_client_utils::DaemonConnector,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    paths: Vec<StorePath>,
    filter: bool,
    use_substitutes: bool,
) -> eyre::Result<()> {
    let paths = if filter {
        filter_missing(local_db, &connector, gcroot, paths, 10).await?
    } else {
        paths
    };
    let paths = if use_substitutes {
        metrics.add_substituting_path(paths.len() as u64);
        let _ = substitute_paths(&connector, &paths).await;
        metrics.sub_substituting_path(paths.len() as u64);
        let paths = filter_missing(local_db, &connector, gcroot, paths, 10).await?;
        if paths.is_empty() {
            return Ok(());
        }
        paths
    } else {
        paths
    };

    if paths.is_empty() {
        return Ok(());
    }

    let num_paths = paths.len() as u64;
    tracing::debug!("Start importing {num_paths} paths");
    metrics.add_downloading_path(num_paths);

    let stream = client
        .fetch_paths(hydra_proto::StorePaths {
            paths: paths
                .iter()
                .map(|p| ProtoStorePath::from(p.clone()))
                .collect(),
        })
        .await?
        .into_inner();

    let mut conn = connector.connect().await?;
    let imported = store_transfer::import::import(&mut conn, stream).await?;

    // Create GC roots while still holding the connection — the
    // imported paths are temp-rooted on this connection and can't
    // be GC'd until we release it.
    for p in &imported {
        add_gc_root(&gcroot.root, connector.store_dir(), p);
    }
    drop(conn);

    metrics.sub_downloading_path(num_paths);
    tracing::debug!("Finished importing {} paths", imported.len());
    Ok(())
}

#[tracing::instrument(skip(client, connector, metrics, requisites), fields(%gcroot, %drv), err)]
#[allow(clippy::too_many_arguments)]
async fn import_requisites<T: IntoIterator<Item = StorePath>>(
    client: &mut BuilderClient,
    local_db: &LocalNixDb,
    connector: daemon_client_utils::DaemonConnector,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    drv: &StorePath,
    requisites: T,
    max_concurrent_downloads: usize,
    use_substitutes: bool,
) -> eyre::Result<()> {
    let requisites = filter_missing(
        local_db,
        &connector,
        gcroot,
        requisites.into_iter().collect(),
        50,
    )
    .await?;

    let (input_drvs, input_srcs): (Vec<_>, Vec<_>) =
        requisites.into_iter().partition(StorePath::is_derivation);

    for srcs in input_srcs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            local_db,
            connector.clone(),
            metrics.clone(),
            gcroot,
            srcs.to_vec(),
            true,
            use_substitutes,
        )
        .await?;
    }

    for drvs in input_drvs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            local_db,
            connector.clone(),
            metrics.clone(),
            gcroot,
            drvs.to_vec(),
            true,
            false, // never use substitute for drvs
        )
        .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(client, local_db, connector, metrics), err)]
async fn upload_nars_regular(
    mut client: BuilderClient,
    local_db: &LocalNixDb,
    connector: daemon_client_utils::DaemonConnector,
    metrics: Arc<crate::metrics::Metrics>,
    nars: Vec<StorePath>,
) -> eyre::Result<()> {
    // query_closure_infos returns ValidPathInfos in dependency order with
    // path infos already populated, so we don't need to re-query.
    let closure = local_db
        .query_closure_infos(nars)
        .await
        .map_err(|e| eyre::eyre!("failed to compute closure: {e}"))?;

    // Filter out paths the queue-runner already has.
    let closure = {
        use futures::stream::StreamExt as _;

        futures::StreamExt::map(tokio_stream::iter(closure), |vpi| {
            let mut client = client.clone();
            async move {
                if client
                    .has_path(ProtoStorePath::from(vpi.path.clone()))
                    .await
                    .is_ok_and(|r| r.into_inner().has_path)
                {
                    None
                } else {
                    Some(vpi)
                }
            }
        })
        .buffered(10)
        .filter_map(|o| async { o })
        .collect::<Vec<harmonia_store_path_info::ValidPathInfo>>()
        .await
    };
    if closure.is_empty() {
        return Ok(());
    }

    tracing::info!("Start uploading paths to queue runner directly");
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<
        Result<hydra_proto::AddToStoreRequest, tonic::Status>,
    >();
    let before_upload = Instant::now();
    let nars_len = closure.len() as u64;

    metrics.add_uploading_path(nars_len);

    let nars: Vec<_> = closure.iter().map(|vpi| vpi.path.clone()).collect();
    let infos: HashMap<_, _> = closure
        .into_iter()
        .map(|vpi| (vpi.path, vpi.info))
        .collect();

    let export_connector = connector.clone();
    let sender = tokio::spawn(async move {
        let mut conn = export_connector.connect().await?;
        store_transfer::export::export(&mut conn, &nars, &infos, &tx).await
    });

    let upload = client
        .build_result(tokio_stream::StreamExt::filter_map(
            tokio_stream::wrappers::UnboundedReceiverStream::new(rx),
            Result::ok,
        ))
        .map_err(Into::<eyre::Report>::into);

    let (upload_result, sender_result) = futures::future::join(upload, sender).await;
    upload_result?;
    sender_result??;

    tracing::info!(
        "Finished uploading paths to queue runner directly. elapsed={:?}",
        before_upload.elapsed()
    );

    metrics.sub_uploading_path(nars_len);
    Ok(())
}

/// NARs uploaded concurrently across all builds. Enough to hide ~200 ms S3
/// round-trips on a 1 Gb/s link with small NARs; bounded to cap buffer memory
/// and to stay within the local-nix-db connection pool each upload queries for
/// path info.
pub const GLOBAL_NAR_UPLOAD_CONCURRENCY: usize = 16;

#[tracing::instrument(skip(client, connector, upload_semaphore), err)]
#[allow(clippy::too_many_arguments)]
async fn upload_nars_presigned(
    client: BuilderClient,
    local_db: &LocalNixDb,
    upload_client: PresignedUploadClient,
    connector: daemon_client_utils::DaemonConnector,
    output_paths: &[StorePath],
    opts: hydra_proto::PresignedUploadOpts,
    build_id: &str,
    machine_id: &str,
    upload_semaphore: &Arc<tokio::sync::Semaphore>,
) -> eyre::Result<()> {
    use futures::stream::StreamExt as _;

    tracing::info!("Start uploading paths using presigned urls");
    let before_upload = Instant::now();

    // query_closure_infos returns path infos in dependency order, so no
    // need to re-query.
    let closure = local_db.query_closure_infos(output_paths.to_vec()).await?;

    let path_info_map: HashMap<_, _> = closure
        .iter()
        .map(|vpi| (vpi.path.clone(), vpi.info.clone()))
        .collect();
    let paths_to_upload: Vec<_> = closure.iter().map(|vpi| vpi.path.clone()).collect();
    let path_infos = Arc::new(path_info_map);

    let nix_config = daemon_client_utils::parse_nix_remote().ok();
    let debug_store_dir: std::path::PathBuf = nix_config
        .as_ref()
        .and_then(daemon_client_utils::NixDaemonStoreConfig::real_store_dir)
        .unwrap_or_else(|| connector.store_dir().to_string().into());

    let mut nars = Vec::with_capacity(paths_to_upload.len());
    let mut stream = tokio_stream::iter(paths_to_upload.clone())
        .map(|path| {
            let path_infos = path_infos.clone();
            let debug_store_dir = debug_store_dir.clone();
            async move {
                let debug_info_ids = if opts.upload_debug_info {
                    binary_cache::get_debug_info_build_ids(&debug_store_dir, &path).await?
                } else {
                    Vec::new()
                };
                let Some((narhash, nar_size)) =
                    path_infos.get(&path).map(|i| (i.nar_hash, i.nar_size))
                else {
                    return Ok(None);
                };
                Ok::<_, eyre::Report>(Some((path, narhash, nar_size, debug_info_ids)))
            }
        })
        .buffered(10);

    while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
        if let Some(v) = v? {
            nars.push(v);
        }
    }

    if nars.len() != paths_to_upload.len() {
        return Err(eyre::eyre!(
            "Mismatch between paths_to_upload ({}) and paths_with_narhash ({})",
            paths_to_upload.len(),
            nars.len(),
        ));
    }

    let presigned_responses = client
        .request_presigned_urls(build_id, machine_id, nars)
        .await?;

    // The server only mints upload URLs for paths missing from the remote
    // cache, so it returns a subset: closure paths already present are
    // skipped instead of being re-uploaded on every build. More responses
    // than requested would be a protocol bug.
    if presigned_responses.len() > paths_to_upload.len() {
        return Err(eyre::eyre!(
            "Server returned more presigned URLs ({}) than requested NARs ({})",
            presigned_responses.len(),
            paths_to_upload.len(),
        ));
    }

    // Paths are independent and narinfo is written server-side per completion,
    // so upload them concurrently.
    let mut uploads = tokio_stream::iter(presigned_responses)
        .map(|presigned_response| {
            let client = client.clone();
            let upload_client = upload_client.clone();
            let upload_semaphore = upload_semaphore.clone();
            async move {
                let _permit = upload_semaphore.acquire().await?;
                let store_path = StorePath::from_base_path(&presigned_response.store_path)
                    .map_err(|e| eyre::eyre!("invalid store path in presigned response: {e}"))?;
                upload_single_nar_presigned(
                    local_db,
                    &store_path,
                    build_id,
                    machine_id,
                    &presigned_response,
                    &client,
                    &upload_client,
                )
                .await
            }
        })
        .buffer_unordered(GLOBAL_NAR_UPLOAD_CONCURRENCY);

    while let Some(res) = uploads.next().await {
        res?;
    }

    tracing::info!(
        "Finished uploading paths using presigned urls. elapsed={:?}",
        before_upload.elapsed()
    );
    Ok(())
}

/// Supplies more presigned part URLs over gRPC when a multipart upload exhausts
/// its initial estimate (compressed size is unknown when the server presigns).
struct GrpcMoreParts {
    client: BuilderClient,
    build_id: String,
    machine_id: String,
    object_key: String,
}

impl MorePartsSource for GrpcMoreParts {
    fn more_parts<'a>(
        &'a self,
        upload_id: &'a str,
        start_part: u32,
        count: u32,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<PresignedPart>, CacheError>> + Send + 'a>> {
        Box::pin(async move {
            let req = hydra_proto::MultipartPartsRequest {
                build_id: self.build_id.clone(),
                machine_id: self.machine_id.clone(),
                object_key: self.object_key.clone(),
                upload_id: upload_id.to_owned(),
                start_part_number: start_part,
                num_parts: count,
            };
            let parts = self
                .client
                .request_multipart_parts(req)
                .await
                .map_err(|e| CacheError::PresignedUrlError {
                    path: self.object_key.clone(),
                    reason: e.to_string(),
                })?;
            Ok(parts
                .into_iter()
                .map(|p| PresignedPart {
                    part_number: p.part_number,
                    url: p.url,
                })
                .collect())
        })
    }
}

/// Translate a queue-runner presigned response into the binary-cache upload
/// request, returning the object key alongside it.
fn presigned_request_from_response(
    presigned_response: &hydra_proto::PresignedNarResponse,
) -> eyre::Result<(String, binary_cache::PresignedUploadResponse)> {
    let nar_upload = presigned_response
        .nar_upload
        .as_ref()
        .ok_or_else(|| eyre::eyre!("nar_upload information is missing"))?;

    let multipart = nar_upload
        .multipart
        .as_ref()
        .map(|mp| binary_cache::PresignedMultipart {
            key: nar_upload.path.clone(),
            upload_id: mp.upload_id.clone(),
            part_size: mp.part_size,
            parts: mp
                .parts
                .iter()
                .map(|p| PresignedPart {
                    part_number: p.part_number,
                    url: p.url.clone(),
                })
                .collect(),
        });

    let request = binary_cache::PresignedUploadResponse {
        nar_url: presigned_response.nar_url.clone(),
        nar_upload: PresignedUpload::new(
            nar_upload.path.clone(),
            nar_upload.url.clone(),
            nar_upload.compression.parse().unwrap_or(Compression::None),
            nar_upload.compression_level,
        )
        .with_multipart(multipart),
        ls_upload: presigned_response.ls_upload.as_ref().map(|ls| {
            PresignedUpload::new(
                ls.path.clone(),
                ls.url.clone(),
                ls.compression.parse().unwrap_or(Compression::None),
                ls.compression_level,
            )
        }),
        debug_info_upload: presigned_response
            .debug_info_upload
            .iter()
            .map(|p| {
                PresignedUpload::new(
                    p.path.clone(),
                    p.url.clone(),
                    p.compression.parse().unwrap_or(Compression::None),
                    p.compression_level,
                )
            })
            .collect(),
    };

    Ok((nar_upload.path.clone(), request))
}

#[tracing::instrument(skip(local_db, nar_path, presigned_response), err)]
async fn upload_single_nar_presigned(
    local_db: &LocalNixDb,
    nar_path: &StorePath,
    build_id: &str,
    machine_id: &str,
    presigned_response: &hydra_proto::PresignedNarResponse,
    client: &BuilderClient,
    upload_client: &PresignedUploadClient,
) -> eyre::Result<()> {
    // Presigned upload requires constructing NarInfo from path info.
    let narinfo: binary_cache::NarInfo = {
        let info = local_db
            .query_path_info(nar_path)
            .await?
            .ok_or_else(|| eyre::eyre!("path not found: {nar_path}"))?
            .info;
        binary_cache::narinfo_simple(nar_path, info, Compression::None)
    };
    let (object_key, presigned_request) = presigned_request_from_response(presigned_response)?;

    let more_parts = GrpcMoreParts {
        client: client.clone(),
        build_id: build_id.to_owned(),
        machine_id: machine_id.to_owned(),
        object_key,
    };
    let (updated_narinfo, completion) = upload_client
        .process_presigned_request(
            local_db.store_dir(),
            narinfo,
            presigned_request,
            &more_parts,
        )
        .await?;

    tracing::debug!(
        "Successfully uploaded presigned NAR for {} to {}",
        nar_path,
        updated_narinfo.info.url.as_deref().unwrap_or("")
    );

    if updated_narinfo.info.download_hash.is_some() && updated_narinfo.info.download_size.is_some()
    {
        let completion_msg = hydra_proto::PresignedUploadComplete {
            build_id: build_id.to_owned(),
            machine_id: machine_id.to_owned(),
            nar_info: Some((&updated_narinfo).into()),
            multipart: completion.map(|c| hydra_proto::MultipartCompletion {
                object_key: c.key,
                upload_id: c.upload_id,
                parts: c
                    .parts
                    .into_iter()
                    .map(|p| hydra_proto::MultipartCompletedPart {
                        part_number: p.part_number,
                        etag: p.etag,
                    })
                    .collect(),
            }),
        };

        client
            .notify_presigned_upload_complete(completion_msg)
            .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(local_db, connector, output_infos), fields(%drv), ret(level = tracing::Level::DEBUG), err)]
#[allow(clippy::too_many_arguments)]
async fn new_success_build_result_info(
    local_db: &LocalNixDb,
    connector: daemon_client_utils::DaemonConnector,
    machine_id: uuid::Uuid,
    drv: &StorePath,
    output_infos: &BTreeMap<OutputName, harmonia_store_path_info::ValidPathInfo>,
    timings: BuildTimings,
    build_id: String,
) -> eyre::Result<BuildResultInfo> {
    let outputs: BTreeMap<_, _> = output_infos
        .iter()
        .map(|(name, vpi)| (name.clone(), vpi.path.clone()))
        .collect();
    let real_store_dir = daemon_client_utils::parse_nix_remote()
        .ok()
        .and_then(|c| c.real_store_dir())
        .unwrap_or_else(|| connector.store_dir().to_string().into());
    let real_store_path = &real_store_dir;
    let fs = nix_support::FilesystemOperations {
        real_store_dir: real_store_path.to_owned(),
    };
    let per_output_nix_support = Box::pin(nix_support::parse_nix_support_from_outputs(
        connector.store_dir(),
        &real_store_dir.to_path_buf(),
        &fs,
        &outputs,
    ))
    .await?;

    let mut result_infos = std::collections::HashMap::new();
    for (name, vpi) in output_infos {
        let ns = per_output_nix_support
            .get(name)
            .cloned()
            .unwrap_or_default();
        result_infos.insert(
            name.to_string(),
            OutputInfo {
                path: Some(ProtoStorePath::from(vpi.path.clone())),
                closure_size: local_db.compute_closure_size(&vpi.path).await,
                nar_size: vpi.info.nar_size,
                nar_hash: {
                    let h: harmonia_utils_hash::Hash = vpi.info.nar_hash.into();
                    Some((&h).into())
                },
                nix_support: Some(ns.into()),
            },
        );
    }

    Ok(BuildResultInfo {
        build_id,
        machine_id: machine_id.to_string(),
        import_time_ms: u64::try_from(timings.import_elapsed.as_millis())?,
        build_time_ms: u64::try_from(timings.build_elapsed.as_millis())?,
        upload_time_ms: u64::try_from(timings.upload_elapsed.as_millis())?,
        result_state: BuildResultState::Success as i32,
        output_infos: result_infos,
        error_msg: None,
    })
}

fn build_client_options(
    build_cores: u32,
    max_silent_time: i32,
    max_log_size: u64,
    build_timeout: i32,
    presigned: bool,
) -> harmonia_protocol::types::ClientOptions {
    let mut options = harmonia_protocol::types::ClientOptions::default();
    options.max_silent_time = i64::from(max_silent_time);
    options.build_cores = build_cores;
    options
        .other_settings
        .insert("max-log-size".to_string(), max_log_size.to_string().into());
    options
        .other_settings
        .insert("timeout".to_string(), build_timeout.to_string().into());
    if presigned {
        // With presigned uploads, inputs are substituted from a binary cache
        // that other builders write to continuously; a cached negative narinfo
        // lookup makes the daemon fail substitution of a just-uploaded input
        // during the build.
        options
            .other_settings
            .insert("narinfo-cache-negative-ttl".to_string(), "0".into());
    }
    options
}

#[cfg(test)]
mod tests {
    use super::strip_ansi;

    #[test]
    fn strip_ansi_removes_csi_sequences() {
        let input = "build failed: Cannot build '\u{1b}[35;1m/nix/store/x.drv\u{1b}[0m'. \
             Reason: \u{1b}[31;1m1 dependency failed\u{1b}[0m.";
        assert_eq!(
            strip_ansi(input),
            "build failed: Cannot build '/nix/store/x.drv'. Reason: 1 dependency failed."
        );
    }

    #[test]
    fn strip_ansi_leaves_plain_text_untouched() {
        assert_eq!(strip_ansi("no escapes here"), "no escapes here");
    }

    #[test]
    fn strip_ansi_removes_osc_hyperlinks() {
        // gcc-style terminal hyperlink: OSC 8 ;; URI BEL <text> OSC 8 ;; BEL
        let input = "see \u{1b}]8;;https://example.com\u{07}the docs\u{1b}]8;;\u{07} now";
        assert_eq!(strip_ansi(input), "see the docs now");
    }
}
