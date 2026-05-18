use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Instant;

use anyhow::Context as _;
use backon::RetryableWithContext as _;
use futures::TryFutureExt as _;
use hashbrown::HashMap;

use crate::grpc::BuilderClient;
use crate::types::BuildTimings;
use binary_cache::{Compression, PresignedUpload, PresignedUploadClient};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{ParseStorePathError, StorePath};
use hydra_proto::ProtoStorePath;
use hydra_proto::{
    AbortMessage, BuildMessage, BuildResultInfo, BuildResultState, JoinMessage, OutputInfo,
    PingMessage, PressureState, StepStatus, StepUpdate,
};
use tonic::Request;
const RETRY_MIN_DELAY: tokio::time::Duration = tokio::time::Duration::from_secs(3);
const RETRY_MAX_DELAY: tokio::time::Duration = tokio::time::Duration::from_secs(90);

fn retry_strategy() -> backon::ExponentialBuilder {
    backon::ExponentialBuilder::default()
        .with_jitter()
        .with_min_delay(RETRY_MIN_DELAY)
        .with_max_delay(RETRY_MAX_DELAY)
}

/// Submit a build result to the queue-runner with retries.
async fn submit_build_result(
    client: &BuilderClient,
    result: BuildResultInfo,
    context: &'static str,
) -> anyhow::Result<()> {
    let (_, res) = (|tuple: (BuilderClient, BuildResultInfo)| async {
        let (mut client, body) = tuple;
        let res = client.complete_build(body.clone()).await;
        ((client, body), res)
    })
    .retry(retry_strategy())
    .sleep(tokio::time::sleep)
    .context((client.clone(), result))
    .notify(|err: &tonic::Status, dur: core::time::Duration| {
        tracing::error!("{context}: err={err}, retrying in={dur:?}");
    })
    .await;
    res.map(|_| ())
        .map_err(anyhow::Error::from)
        .context(context)
}

#[derive(thiserror::Error, Debug)]
pub enum JobFailure {
    #[error("Build failure: `{0}`")]
    Build(anyhow::Error),
    #[error("Preparing failure: `{0}`")]
    Preparing(anyhow::Error),
    #[error("Import failure: `{0}`")]
    Import(anyhow::Error),
    #[error("Upload failure: `{0}`")]
    Upload(anyhow::Error),
    #[error("Post processing failure: `{0}`")]
    PostProcessing(anyhow::Error),
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct NixBuildOutputs {
    drv_path: String,
    outputs: BTreeMap<OutputName, String>,
}

impl From<JobFailure> for BuildResultState {
    fn from(item: JobFailure) -> Self {
        match item {
            JobFailure::Build(_) => Self::BuildFailure,
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
    handle: tokio::task::JoinHandle<anyhow::Result<()>>,
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

#[derive(Debug)]
pub struct State {
    pub id: uuid::Uuid,
    pub hostname: String,
    pub config: Config,
    pub max_concurrent_downloads: AtomicU32,

    active_builds: parking_lot::RwLock<HashMap<uuid::Uuid, Arc<BuildInfo>>>,
    pub client: BuilderClient,
    pub halt: AtomicBool,
    pub metrics: Arc<crate::metrics::Metrics>,
    upload_client: PresignedUploadClient,
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
    pub async fn new(cli: &super::config::Cli) -> anyhow::Result<Arc<Self>> {
        let nix_config = crate::nix_config::NixConfig::load()?;
        let nix_remote = daemon_client_utils::parse_nix_remote().map_err(|e| anyhow::anyhow!(e))?;

        let logname = std::env::var("LOGNAME").context("LOGNAME not set")?;
        let gcroots = nix_remote
            .state_dir
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots/builder");
        fs_err::tokio::create_dir_all(&gcroots).await?;

        let state = Arc::new(Self {
            id: uuid::Uuid::new_v4(),
            hostname: gethostname::gethostname().into_string().map_err(|v| {
                anyhow::anyhow!(
                    "Couldn't convert hostname to string! OsString={}",
                    v.display()
                )
            })?,
            active_builds: parking_lot::RwLock::new(HashMap::with_capacity(10)),
            config: Config {
                ping_interval: cli.ping_interval,
                speed_factor: cli.speed_factor,
                max_jobs: cli.max_jobs,
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
            max_concurrent_downloads: 5.into(),
            client: crate::grpc::init_client(cli).await?,
            halt: false.into(),
            metrics: Arc::new(crate::metrics::Metrics::default()),
            upload_client: PresignedUploadClient::new(),
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
    pub async fn get_join_message(&self) -> anyhow::Result<JoinMessage> {
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
    pub fn get_ping_message(&self) -> anyhow::Result<PingMessage> {
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
            pressure: sysinfo.pressure.map(|p| PressureState {
                cpu_some: p.cpu_some,
                mem_some: p.mem_some,
                mem_full: p.mem_full,
                io_some: p.io_some,
                io_full: p.io_full,
                irq_full: p.irq_full,
            }),
            build_dir_free_percent: sysinfo.build_dir_free_percent,
            store_free_percent: sysinfo.store_free_percent,
            current_substituting_path_count: self.metrics.get_substituting_path_count(),
            current_uploading_path_count: self.metrics.get_uploading_path_count(),
            current_downloading_path_count: self.metrics.get_downloading_path_count(),
        })
    }

    #[tracing::instrument(skip(self, m), fields(drv=?m.drv))]
    pub fn schedule_build(self: Arc<Self>, m: BuildMessage) -> anyhow::Result<()> {
        if self.halt.load(Ordering::SeqCst) {
            tracing::warn!("State is set to halt, will no longer accept new builds!");
            return Err(anyhow::anyhow!("State set to halt."));
        }

        let drv = m
            .drv
            .clone()
            .ok_or_else(|| anyhow::anyhow!("missing drv"))?
            .0;
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
                            anyhow::bail!("Build of {drv} was cancelled {e}, not reporting Error");
                        }

                        tracing::error!("Build of {drv} failed with {e}");
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
                            result_state: BuildResultState::from(e) as i32,
                            output_infos: std::collections::HashMap::new(),
                        };

                        submit_build_result(
                            &self_.client,
                            failed_build,
                            "Failed to submit build failure info",
                        )
                        .await?;
                    }
                }
                Ok(())
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
    pub fn abort_build(&self, m: &AbortMessage) -> anyhow::Result<()> {
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

    #[tracing::instrument(skip(self, m), fields(drv=?m.drv), err)]
    #[allow(clippy::too_many_lines)]
    async fn process_build(
        &self,
        m: BuildMessage,
        timings: &mut BuildTimings,
    ) -> Result<(), JobFailure> {
        let nix_config = daemon_client_utils::parse_nix_remote()
            .map_err(|e| JobFailure::Preparing(anyhow::anyhow!(e)))?;
        let daemon_socket = nix_config.socket;
        let store_dir = nix_config.store_dir;
        let pool = harmonia_store_remote::ConnectionPool::with_store_dir(
            &daemon_socket,
            store_dir.clone(),
            harmonia_store_remote::PoolConfig::default(),
        );

        let machine_id = self.id;
        let drv = m
            .drv
            .ok_or(JobFailure::Preparing(anyhow::anyhow!("missing drv")))?
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
        let requisites = client
            .fetch_requisites(ProtoStorePath::from(drv.clone()))
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .into_inner()
            .requisites;

        import_requisites(
            &mut client,
            pool.clone(),
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
        let (mut child, stdout, stderr) = crate::realise::realise_drv(
            pool.store_dir(),
            &drv,
            m.max_log_size,
            m.max_silent_time,
            m.build_timeout,
        )
        .await
        .map_err(|e| JobFailure::Build(e.into()))?;

        // The build_log RPC streams stderr to the queue-runner and only
        // resolves once the child closes stderr (i.e. the build finished).
        // A transport error here (e.g. nginx sending an HTTP/2 GOAWAY after
        // hitting keepalive_requests) says nothing about whether the
        // derivation builds, so it must not be reported as a BuildFailure
        // (which is non-retryable and cascades to every dependent build).
        // Map it to Upload so the queue-runner retries the step instead.
        client
            .build_log(Request::new(crate::utils::compressed_log_stream(
                &drv, stderr,
            )))
            .await
            .map_err(|e| {
                JobFailure::Upload(
                    anyhow::Error::from(e).context("failed to stream build log to queue-runner"),
                )
            })?;

        let status = child
            .wait()
            .await
            .map_err(|e| JobFailure::Build(e.into()))?;
        if !status.success() {
            return Err(JobFailure::Build(anyhow::anyhow!(
                "nix build exited with {status}"
            )));
        }

        // Parse JSON output from stdout (one line).
        use tokio_stream::StreamExt as _;
        let outputs_line = std::pin::pin!(stdout.timeout(tokio::time::Duration::from_millis(100)))
            .next()
            .await
            .ok_or_else(|| {
                JobFailure::PostProcessing(anyhow::anyhow!("Child did not print outputs"))
            })?
            .map_err(|e| JobFailure::PostProcessing(e.into()))?
            .map_err(|e| JobFailure::PostProcessing(e.into()))?;

        let mut output_raw: Vec<NixBuildOutputs> = serde_json::from_str(&outputs_line)
            .map_err(|e| JobFailure::PostProcessing(e.into()))?;

        if output_raw.len() != 1 {
            return Err(JobFailure::PostProcessing(anyhow::anyhow!(
                "nix built {} derivations, expecting 1",
                output_raw.len()
            )));
        }

        let actual_out_drv: StorePath = pool
            .store_dir()
            .parse(&output_raw[0].drv_path)
            .map_err(|e: ParseStorePathError| JobFailure::PostProcessing(e.into()))?;
        if actual_out_drv != drv {
            return Err(JobFailure::PostProcessing(anyhow::anyhow!(
                "Nix returned outputs for {actual_out_drv} when we expected {drv}"
            )));
        }

        let outputs = output_raw
            .pop()
            .expect("checked len == 1")
            .outputs
            .into_iter()
            .map(|(name, path)| Ok((name, pool.store_dir().parse::<StorePath>(&path)?)))
            .collect::<anyhow::Result<BTreeMap<OutputName, StorePath>>>()
            .map_err(JobFailure::PostProcessing)?;

        for o in outputs.values() {
            add_gc_root(&gcroot.root, pool.store_dir(), o);
        }

        timings.build_elapsed = before_build.elapsed();
        tracing::info!("Finished building {drv}");

        // Query path info for each output up front — these are needed both
        // for building the result message and are expected to exist for a
        // successful build.
        let mut output_infos = BTreeMap::new();
        for (name, path) in &outputs {
            let info = daemon_client_utils::query_path_info(&pool, path)
                .await
                .map_err(|e| {
                    JobFailure::PostProcessing(anyhow::anyhow!("query_path_info failed: {e}"))
                })?
                .ok_or_else(|| {
                    JobFailure::PostProcessing(anyhow::anyhow!(
                        "missing path info for output `{name}`"
                    ))
                })?;
            output_infos.insert(
                name.clone(),
                harmonia_store_path_info::ValidPathInfo {
                    path: path.clone(),
                    info,
                },
            );
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
            pool.clone(),
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
            pool.clone(),
            machine_id,
            &drv,
            &output_infos,
            *timings,
            m.build_id.clone(),
        ))
        .await
        .map_err(JobFailure::PostProcessing)?;

        // This part is stupid, if writing doesnt work, we try to write a failure, maybe that works.
        // We retry to ensure that this almost never happens.
        submit_build_result(
            &client,
            build_results,
            "Failed to submit build success info",
        )
        .await
        .map_err(JobFailure::PostProcessing)?;
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

    #[tracing::instrument(skip(self, pool, nars), err)]
    async fn upload_nars(
        &self,
        pool: harmonia_store_remote::ConnectionPool,
        nars: Vec<StorePath>,
        build_id: &str,
        machine_id: &str,
        presigned_url_opts: Option<hydra_proto::PresignedUploadOpts>,
    ) -> anyhow::Result<()> {
        if let Some(opts) = presigned_url_opts {
            upload_nars_presigned(
                self.client.clone(),
                self.upload_client.clone(),
                pool,
                &nars,
                opts,
                build_id,
                machine_id,
            )
            .await
        } else {
            upload_nars_regular(self.client.clone(), pool, self.metrics.clone(), nars).await
        }
    }
}

#[tracing::instrument(skip(pool), fields(%gcroot, %path))]
async fn is_path_missing(
    pool: &harmonia_store_remote::ConnectionPool,
    gcroot: &Gcroot,
    path: StorePath,
) -> anyhow::Result<Option<StorePath>> {
    if daemon_client_utils::is_valid_path(pool, &path).await? {
        add_gc_root(&gcroot.root, pool.store_dir(), &path);
        Ok(None)
    } else {
        Ok(Some(path))
    }
}

/// Keep only paths not yet present in the local store.
async fn filter_missing(
    pool: &harmonia_store_remote::ConnectionPool,
    gcroot: &Gcroot,
    paths: Vec<StorePath>,
    concurrency: usize,
) -> anyhow::Result<Vec<StorePath>> {
    use futures::StreamExt as _;
    futures::StreamExt::map(tokio_stream::iter(paths), |p| {
        is_path_missing(pool, gcroot, p)
    })
    .buffered(concurrency)
    .collect::<Vec<_>>()
    .await
    .into_iter()
    .collect::<anyhow::Result<Vec<_>>>()
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

async fn substitute_paths(
    pool: &harmonia_store_remote::ConnectionPool,
    paths: &[StorePath],
) -> anyhow::Result<()> {
    for p in paths {
        daemon_client_utils::ensure_path(pool, p).await?;
    }
    Ok(())
}

#[tracing::instrument(skip(client, pool, metrics), fields(%gcroot), err)]
async fn import_paths(
    mut client: BuilderClient,
    pool: harmonia_store_remote::ConnectionPool,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    paths: Vec<StorePath>,
    filter: bool,
    use_substitutes: bool,
) -> anyhow::Result<()> {
    let paths = if filter {
        filter_missing(&pool, gcroot, paths, 10).await?
    } else {
        paths
    };
    let paths = if use_substitutes {
        metrics.add_substituting_path(paths.len() as u64);
        let _ = substitute_paths(&pool, &paths).await;
        metrics.sub_substituting_path(paths.len() as u64);
        let paths = filter_missing(&pool, gcroot, paths, 10).await?;
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

    let mut guard = pool.acquire().await?;
    let imported = store_transfer::import::import(&mut guard, stream).await?;

    // Create GC roots while still holding the connection — the
    // imported paths are temp-rooted on this connection and can't
    // be GC'd until we release it.
    for p in &imported {
        add_gc_root(&gcroot.root, pool.store_dir(), p);
    }
    drop(guard);

    metrics.sub_downloading_path(num_paths);
    tracing::debug!("Finished importing {} paths", imported.len());
    Ok(())
}

#[tracing::instrument(skip(client, pool, metrics, requisites), fields(%gcroot, %drv), err)]
#[allow(clippy::too_many_arguments)]
async fn import_requisites<T: IntoIterator<Item = StorePath>>(
    client: &mut BuilderClient,
    pool: harmonia_store_remote::ConnectionPool,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    drv: &StorePath,
    requisites: T,
    max_concurrent_downloads: usize,
    use_substitutes: bool,
) -> anyhow::Result<()> {
    let requisites = filter_missing(&pool, gcroot, requisites.into_iter().collect(), 50).await?;

    let (input_drvs, input_srcs): (Vec<_>, Vec<_>) =
        requisites.into_iter().partition(StorePath::is_derivation);

    for srcs in input_srcs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            pool.clone(),
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
            pool.clone(),
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

#[tracing::instrument(skip(client, pool, metrics), err)]
async fn upload_nars_regular(
    mut client: BuilderClient,
    pool: harmonia_store_remote::ConnectionPool,
    metrics: Arc<crate::metrics::Metrics>,
    nars: Vec<StorePath>,
) -> anyhow::Result<()> {
    // Compute full closure by walking references via daemon protocol.
    // query_closure returns ValidPathInfos in dependency order with
    // path infos already populated, so we don't need to re-query.
    let closure = binary_cache::query_closure(&pool, &nars)
        .await
        .map_err(|e| anyhow::anyhow!("failed to compute closure: {e}"))?;

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

    let export_pool = pool.clone();
    let sender = tokio::spawn(async move {
        let mut guard = export_pool.acquire().await?;
        store_transfer::export::export(&mut guard, &nars, &infos, &tx).await
    });

    let upload = client
        .build_result(tokio_stream::StreamExt::filter_map(
            tokio_stream::wrappers::UnboundedReceiverStream::new(rx),
            Result::ok,
        ))
        .map_err(Into::<anyhow::Error>::into);

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

#[tracing::instrument(skip(client, pool), err)]
async fn upload_nars_presigned(
    mut client: BuilderClient,
    upload_client: PresignedUploadClient,
    pool: harmonia_store_remote::ConnectionPool,
    output_paths: &[StorePath],
    opts: hydra_proto::PresignedUploadOpts,
    build_id: &str,
    machine_id: &str,
) -> anyhow::Result<()> {
    use futures::stream::StreamExt as _;

    tracing::info!("Start uploading paths using presigned urls");
    let before_upload = Instant::now();

    // Compute full closure by walking references. Returns path infos
    // in dependency order, so no need to re-query.
    let closure = daemon_client_utils::query_closure(&pool, output_paths).await?;

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
        .unwrap_or_else(|| pool.store_dir().to_string().into());

    let mut nars = Vec::with_capacity(paths_to_upload.len());
    let mut stream = tokio_stream::iter(paths_to_upload.clone())
        .map(|path| {
            let path_infos = path_infos.clone();
            let debug_store_dir = debug_store_dir.clone();
            async move {
                let debug_info_ids =
                    binary_cache::get_debug_info_build_ids(&debug_store_dir, &path)
                        .await
                        .unwrap_or_default();
                let Some(narhash) = path_infos.get(&path).map(|i| i.nar_hash) else {
                    return Ok(None);
                };
                Ok::<_, anyhow::Error>(Some((path, narhash, debug_info_ids)))
            }
        })
        .buffered(10);

    while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
        if let Some(v) = v? {
            nars.push(v);
        }
    }

    if nars.len() != paths_to_upload.len() {
        return Err(anyhow::anyhow!(
            "Mismatch between paths_to_upload ({}) and paths_with_narhash ({})",
            paths_to_upload.len(),
            nars.len(),
        ));
    }

    let presigned_responses = client
        .request_presigned_urls(build_id, machine_id, nars)
        .await?;

    if presigned_responses.len() != paths_to_upload.len() {
        return Err(anyhow::anyhow!(
            "Mismatch between requested NARs ({}) and presigned URLs ({})",
            paths_to_upload.len(),
            presigned_responses.len()
        ));
    }

    for presigned_response in presigned_responses {
        upload_single_nar_presigned(
            &pool,
            &StorePath::from_base_path(&presigned_response.store_path)
                .map_err(|e| anyhow::anyhow!("invalid store path in presigned response: {e}"))?,
            build_id,
            machine_id,
            &presigned_response,
            &mut client,
            &upload_client,
        )
        .await?;
    }

    tracing::info!(
        "Finished uploading paths using presigned urls. elapsed={:?}",
        before_upload.elapsed()
    );
    Ok(())
}

#[tracing::instrument(skip(pool, nar_path, presigned_response), err)]
async fn upload_single_nar_presigned(
    pool: &harmonia_store_remote::ConnectionPool,
    nar_path: &StorePath,
    build_id: &str,
    machine_id: &str,
    presigned_response: &hydra_proto::PresignedNarResponse,
    client: &mut BuilderClient,
    upload_client: &PresignedUploadClient,
) -> anyhow::Result<()> {
    // Presigned upload requires constructing NarInfo from daemon path info.
    let narinfo: binary_cache::NarInfo = {
        let info = daemon_client_utils::query_path_info(pool, nar_path)
            .await?
            .ok_or_else(|| anyhow::anyhow!("path not found: {nar_path}"))?;
        binary_cache::narinfo_simple(nar_path, info, Compression::None)
    };
    let nar_upload = presigned_response
        .nar_upload
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("nar_upload information is missing"))?;

    let presigned_request = binary_cache::PresignedUploadResponse {
        nar_url: presigned_response.nar_url.clone(),
        nar_upload: PresignedUpload::new(
            nar_upload.path.clone(),
            nar_upload.url.clone(),
            nar_upload.compression.parse().unwrap_or(Compression::None),
            nar_upload.compression_level,
        ),
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

    let updated_narinfo = upload_client
        .process_presigned_request(pool, narinfo, presigned_request)
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
        };

        client
            .notify_presigned_upload_complete(completion_msg)
            .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(pool, output_infos), fields(%drv), ret(level = tracing::Level::DEBUG), err)]
async fn new_success_build_result_info(
    pool: harmonia_store_remote::ConnectionPool,
    machine_id: uuid::Uuid,
    drv: &StorePath,
    output_infos: &BTreeMap<OutputName, harmonia_store_path_info::ValidPathInfo>,
    timings: BuildTimings,
    build_id: String,
) -> anyhow::Result<BuildResultInfo> {
    let outputs: BTreeMap<_, _> = output_infos
        .iter()
        .map(|(name, vpi)| (name.clone(), vpi.path.clone()))
        .collect();
    let real_store_dir = daemon_client_utils::parse_nix_remote()
        .ok()
        .and_then(|c| c.real_store_dir())
        .unwrap_or_else(|| pool.store_dir().to_string().into());
    let real_store_path = &real_store_dir;
    let fs = nix_support::FilesystemOperations {
        real_store_dir: real_store_path.to_owned(),
    };
    let per_output_nix_support = Box::pin(nix_support::parse_nix_support_from_outputs(
        pool.store_dir(),
        real_store_path,
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
                closure_size: compute_closure_size(&pool, &vpi.path).await,
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
    })
}

/// Compute the total NAR size of a path's closure by walking references.
async fn compute_closure_size(
    pool: &harmonia_store_remote::ConnectionPool,
    path: &StorePath,
) -> u64 {
    daemon_client_utils::compute_closure_size(pool, path).await
}
