use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Instant;

use anyhow::Context as _;
use backon::RetryableWithContext as _;
use futures::TryFutureExt as _;
use hashbrown::HashMap;
use tonic::Request;
use tracing::Instrument as _;

use crate::grpc::{BuilderClient, runner_v1};
use crate::types::BuildTimings;
use binary_cache::{Compression, PresignedUpload, PresignedUploadClient};
use nix_utils::BaseStore as _;
use runner_v1::{
    AbortMessage, BuildMessage, BuildMetric, BuildProduct, BuildResultInfo, BuildResultState,
    FetchRequisitesRequest, JoinMessage, LogChunk, NarData, NixSupport, Output, OutputNameOnly,
    OutputWithPath, PingMessage, PressureState, StepStatus, StepUpdate, StorePaths, output,
};

include!(concat!(env!("OUT_DIR"), "/proto_version.rs"));

const RETRY_MIN_DELAY: tokio::time::Duration = tokio::time::Duration::from_secs(3);
const RETRY_MAX_DELAY: tokio::time::Duration = tokio::time::Duration::from_secs(90);

fn retry_strategy() -> backon::ExponentialBuilder {
    backon::ExponentialBuilder::default()
        .with_jitter()
        .with_min_delay(RETRY_MIN_DELAY)
        .with_max_delay(RETRY_MAX_DELAY)
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
    drv_path: nix_utils::StorePath,
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
    pub fn new(path: std::path::PathBuf) -> std::io::Result<Self> {
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
        nix_utils::set_verbosity(1);

        let logname = std::env::var("LOGNAME").context("LOGNAME not set")?;
        let nix_state_dir =
            std::env::var("NIX_STATE_DIR").unwrap_or_else(|_| "/nix/var/nix/".to_owned());
        let gcroots = std::path::PathBuf::from(nix_state_dir)
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots");
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
                        out.push(nix_utils::get_this_system());
                        out.extend(nix_utils::get_extra_platforms());
                        out
                    },
                    Clone::clone,
                ),
                supported_features: cli
                    .supported_features
                    .as_ref()
                    .map_or_else(nix_utils::get_system_features, Clone::clone),
                mandatory_features: cli.mandatory_features.clone().unwrap_or_default(),
                cgroups: nix_utils::get_use_cgroups(),
                use_substitutes: cli.use_substitutes,
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
            substituters: nix_utils::get_substituters(),
            use_substitutes: self.config.use_substitutes,
            nix_version: nix_utils::get_nix_version(),
        })
    }

    #[tracing::instrument(skip(self), err)]
    pub fn get_ping_message(&self) -> anyhow::Result<PingMessage> {
        let sysinfo = crate::system::SystemLoad::new(&nix_utils::get_build_dir())?;

        Ok(PingMessage {
            machine_id: self.id.to_string(),
            load1: sysinfo.load_avg_1,
            load5: sysinfo.load_avg_5,
            load15: sysinfo.load_avg_15,
            mem_usage: sysinfo.mem_usage,
            pressure: sysinfo.pressure.map(|p| PressureState {
                cpu_some: p.cpu_some.map(Into::into),
                mem_some: p.mem_some.map(Into::into),
                mem_full: p.mem_full.map(Into::into),
                io_some: p.io_some.map(Into::into),
                io_full: p.io_full.map(Into::into),
                irq_full: p.irq_full.map(Into::into),
            }),
            build_dir_free_percent: sysinfo.build_dir_free_percent,
            store_free_percent: sysinfo.store_free_percent,
            current_substituting_path_count: self.metrics.get_substituting_path_count(),
            current_uploading_path_count: self.metrics.get_uploading_path_count(),
            current_downloading_path_count: self.metrics.get_downloading_path_count(),
        })
    }

    #[tracing::instrument(skip(self, m), fields(drv=%m.drv))]
    pub fn schedule_build(self: Arc<Self>, m: BuildMessage) -> anyhow::Result<()> {
        if self.halt.load(Ordering::SeqCst) {
            tracing::warn!("State is set to halt, will no longer accept new builds!");
            return Err(anyhow::anyhow!("State set to halt."));
        }

        let drv = nix_utils::StorePath::new(&m.drv);
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
                                "Build of {drv} was cancelled {e}, not reporting Error"
                            );
                            return;
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
                            nix_support: None,
                            outputs: vec![],
                        };

                        if let (_, Err(e)) = (|tuple: (BuilderClient, BuildResultInfo)| async {
                            let (mut client, body) = tuple;
                            let res = client.complete_build(body.clone()).await;
                            ((client, body), res)
                        })
                        .retry(retry_strategy())
                        .sleep(tokio::time::sleep)
                        .context((self_.client.clone(), failed_build))
                        .notify(|err: &tonic::Status, dur: core::time::Duration| {
                            tracing::error!("Failed to submit build failure info: err={err}, retrying in={dur:?}");
                        })
                        .await
                        {
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

    fn contains_build(&self, drv: &nix_utils::StorePath) -> bool {
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

    #[tracing::instrument(skip(self, m), fields(drv=%m.drv), err)]
    #[allow(clippy::too_many_lines)]
    async fn process_build(
        &self,
        m: BuildMessage,
        timings: &mut BuildTimings,
    ) -> Result<(), JobFailure> {
        // we dont use anyhow here because we manually need to write the correct build status
        // to the queue runner.
        use tokio_stream::StreamExt as _;

        let store = nix_utils::LocalStore::init();

        let machine_id = self.id;
        let drv = nix_utils::StorePath::new(&m.drv);
        let resolved_drv = m
            .resolved_drv
            .as_ref()
            .map(|v| nix_utils::StorePath::new(v));

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
            .fetch_drv_requisites(FetchRequisitesRequest {
                path: resolved_drv.as_ref().unwrap_or(&drv).base_name().to_owned(),
                include_outputs: false,
            })
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .into_inner()
            .requisites;

        import_requisites(
            &mut client,
            store.clone(),
            self.metrics.clone(),
            &gcroot,
            resolved_drv.as_ref().unwrap_or(&drv),
            requisites
                .into_iter()
                .map(|s| nix_utils::StorePath::new(&s)),
            usize::try_from(self.max_concurrent_downloads.load(Ordering::Relaxed)).unwrap_or(5),
            self.config.use_substitutes,
        )
        .await
        .map_err(JobFailure::Import)?;
        timings.import_elapsed = before_import.elapsed();

        // Resolved drv and drv output paths are the same
        let drv_info = nix_utils::query_drv(&store, &drv)
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .ok_or(JobFailure::Import(anyhow::anyhow!("drv not found")))?;

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::Building as i32,
            })
            .await;
        let before_build = Instant::now();
        let (mut child, mut log_output) = nix_utils::realise_drv(
            &store,
            resolved_drv.as_ref().unwrap_or(&drv),
            &nix_utils::BuildOptions::complete(m.max_log_size, m.max_silent_time, m.build_timeout),
            true,
        )
        .await
        .map_err(|e| JobFailure::Build(e.into()))?;
        let drv2 = drv.clone();
        let log_stream = async_stream::stream! {
            while let Some(chunk) = log_output.next().await {
                match chunk {
                    Ok(chunk) => yield LogChunk {
                        drv: drv2.base_name().to_owned(),
                        data: format!("{chunk}\n").into(),
                    },
                    Err(e) => {
                        tracing::error!("Failed to write log chunk to queue-runner: {e}");
                        break
                    }
                }
            }
        };
        client
            .build_log(Request::new(log_stream))
            .await
            .map_err(|e| JobFailure::Build(e.into()))?;
        let output_paths = drv_info
            .outputs
            .iter()
            .filter_map(|o| o.path.clone())
            .collect::<Vec<_>>();
        nix_utils::validate_statuscode(
            child
                .wait()
                .await
                .map_err(|e| JobFailure::Build(e.into()))?,
        )
        .map_err(|e| JobFailure::Build(e.into()))?;
        for o in &output_paths {
            nix_utils::add_root(&store, &gcroot.root, o);
        }

        timings.build_elapsed = before_build.elapsed();
        tracing::info!("Finished building {drv}");

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                build_id: m.build_id.clone(),
                machine_id: machine_id.to_string(),
                step_status: StepStatus::ReceivingOutputs as i32,
            })
            .await;

        let before_upload = Instant::now();
        self.upload_nars(
            store.clone(),
            output_paths,
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
            store.clone(),
            machine_id,
            &drv,
            drv_info,
            *timings,
            m.build_id.clone(),
        ))
        .await
        .map_err(JobFailure::PostProcessing)?;

        // This part is stupid, if writing doesnt work, we try to write a failure, maybe that works.
        // We retry to ensure that this almost never happens.
        (|tuple: (BuilderClient, BuildResultInfo)| async {
            let (mut client, body) = tuple;
            let res = client.complete_build(body.clone()).await;
            ((client, body), res)
        })
        .retry(retry_strategy())
        .sleep(tokio::time::sleep)
        .context((client.clone(), build_results))
        .notify(|err: &tonic::Status, dur: core::time::Duration| {
            tracing::error!("Failed to submit build success info: err={err}, retrying in={dur:?}");
        })
        .await
        .1
        .map_err(|e| {
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
                .map(|b| b.drv_path.base_name().to_owned())
                .collect::<Vec<_>>()
        };

        let _notify = sd_notify::notify(
            false,
            &[
                sd_notify::NotifyState::Status(&if active.is_empty() {
                    "Building 0 drvs".into()
                } else {
                    format!("Building {} drvs: {}", active.len(), active.join(", "))
                }),
                sd_notify::NotifyState::Ready,
            ],
        );
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

    #[tracing::instrument(skip(self, store, nars), err)]
    async fn upload_nars(
        &self,
        store: nix_utils::LocalStore,
        nars: Vec<nix_utils::StorePath>,
        build_id: &str,
        machine_id: &str,
        presigned_url_opts: Option<crate::grpc::runner_v1::PresignedUploadOpts>,
    ) -> anyhow::Result<()> {
        if let Some(opts) = presigned_url_opts {
            upload_nars_presigned(
                self.client.clone(),
                self.upload_client.clone(),
                store,
                &nars,
                opts,
                build_id,
                machine_id,
            )
            .await
        } else {
            upload_nars_regular(self.client.clone(), store, self.metrics.clone(), nars).await
        }
    }
}

#[tracing::instrument(skip(store), fields(%gcroot, %path))]
async fn filter_missing(
    store: &nix_utils::LocalStore,
    gcroot: &Gcroot,
    path: nix_utils::StorePath,
) -> Option<nix_utils::StorePath> {
    if store.is_valid_path(&path).await {
        nix_utils::add_root(store, &gcroot.root, &path);
        None
    } else {
        Some(path)
    }
}

async fn substitute_paths(
    store: &nix_utils::LocalStore,
    paths: &[nix_utils::StorePath],
) -> anyhow::Result<()> {
    for p in paths {
        store.ensure_path(p).await?;
    }
    Ok(())
}

#[tracing::instrument(skip(client, store, metrics), fields(%gcroot), err)]
async fn import_paths(
    mut client: BuilderClient,
    store: nix_utils::LocalStore,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    paths: Vec<nix_utils::StorePath>,
    filter: bool,
    use_substitutes: bool,
) -> anyhow::Result<()> {
    use futures::StreamExt as _;

    let paths = if filter {
        futures::StreamExt::map(tokio_stream::iter(paths), |p| {
            filter_missing(&store, gcroot, p)
        })
        .buffered(10)
        .filter_map(|o| async { o })
        .collect::<Vec<_>>()
        .await
    } else {
        paths
    };
    let paths = if use_substitutes {
        // we can ignore the error
        metrics.add_substituting_path(paths.len() as u64);
        let _ = substitute_paths(&store, &paths).await;
        metrics.sub_substituting_path(paths.len() as u64);
        let paths = futures::StreamExt::map(tokio_stream::iter(paths), |p| {
            filter_missing(&store, gcroot, p)
        })
        .buffered(10)
        .filter_map(|o| async { o })
        .collect::<Vec<_>>()
        .await;
        if paths.is_empty() {
            return Ok(());
        }
        paths
    } else {
        paths
    };

    tracing::debug!("Start importing paths");
    let stream = client
        .stream_files(StorePaths {
            paths: paths.iter().map(|p| p.base_name().to_owned()).collect(),
        })
        .await?
        .into_inner();

    metrics.add_downloading_path(paths.len() as u64);
    let import_result = store
        .import_paths(
            tokio_stream::StreamExt::map(stream, |s| {
                s.map(|v| v.chunk.into())
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, e))
            }),
            false,
        )
        .await;
    metrics.sub_downloading_path(paths.len() as u64);
    import_result?;
    tracing::debug!("Finished importing paths");

    for p in paths {
        nix_utils::add_root(&store, &gcroot.root, &p);
    }
    Ok(())
}

#[tracing::instrument(skip(client, store, metrics, requisites), fields(%gcroot, %drv), err)]
#[allow(clippy::too_many_arguments)]
async fn import_requisites<T: IntoIterator<Item = nix_utils::StorePath>>(
    client: &mut BuilderClient,
    store: nix_utils::LocalStore,
    metrics: Arc<crate::metrics::Metrics>,
    gcroot: &Gcroot,
    drv: &nix_utils::StorePath,
    requisites: T,
    max_concurrent_downloads: usize,
    use_substitutes: bool,
) -> anyhow::Result<()> {
    use futures::stream::StreamExt as _;

    let requisites = futures::StreamExt::map(tokio_stream::iter(requisites), |p| {
        filter_missing(&store, gcroot, p)
    })
    .buffered(50)
    .filter_map(|o| async { o })
    .collect::<Vec<_>>()
    .await;

    let (input_drvs, input_srcs): (Vec<_>, Vec<_>) = requisites
        .into_iter()
        .partition(nix_utils::StorePath::is_drv);

    for srcs in input_srcs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            store.clone(),
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
            store.clone(),
            metrics.clone(),
            gcroot,
            drvs.to_vec(),
            true,
            false, // never use substitute for drvs
        )
        .await?;
    }

    let full_requisites = client
        .clone()
        .fetch_drv_requisites(FetchRequisitesRequest {
            path: drv.base_name().to_owned(),
            include_outputs: true,
        })
        .await?
        .into_inner()
        .requisites
        .into_iter()
        .map(|s| nix_utils::StorePath::new(&s))
        .collect::<Vec<_>>();
    let full_requisites = futures::StreamExt::map(tokio_stream::iter(full_requisites), |p| {
        filter_missing(&store, gcroot, p)
    })
    .buffered(50)
    .filter_map(|o| async { o })
    .collect::<Vec<_>>()
    .await;

    for other in full_requisites.chunks(max_concurrent_downloads) {
        // we can skip filtering here as we already done that
        import_paths(
            client.clone(),
            store.clone(),
            metrics.clone(),
            gcroot,
            other.to_vec(),
            false,
            use_substitutes,
        )
        .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(client, store, metrics), err)]
async fn upload_nars_regular(
    mut client: BuilderClient,
    store: nix_utils::LocalStore,
    metrics: Arc<crate::metrics::Metrics>,
    nars: Vec<nix_utils::StorePath>,
) -> anyhow::Result<()> {
    let nars = {
        use futures::stream::StreamExt as _;

        futures::StreamExt::map(tokio_stream::iter(nars), |p| {
            let mut client = client.clone();
            async move {
                if client
                    .has_path(runner_v1::StorePath {
                        path: p.base_name().to_owned(),
                    })
                    .await
                    .is_ok_and(|r| r.into_inner().has_path)
                {
                    None
                } else {
                    Some(p)
                }
            }
        })
        .buffered(10)
        .filter_map(|o| async { o })
        .collect::<Vec<_>>()
        .await
    };
    if nars.is_empty() {
        return Ok(());
    }

    tracing::info!("Start uploading paths to queue runner directly");
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<NarData>();
    let before_upload = Instant::now();
    let nars_len = nars.len() as u64;

    metrics.add_uploading_path(nars_len);
    let closure = move |data: &[u8]| {
        let data = Vec::from(data);
        tx.send(NarData { chunk: data }).is_ok()
    };
    let a = client
        .build_result(tokio_stream::wrappers::UnboundedReceiverStream::new(rx))
        .map_err(Into::<anyhow::Error>::into);

    let b = tokio::task::spawn_blocking(move || {
        async move {
            store.export_paths(&nars, closure)?;
            tracing::debug!("Finished exporting paths");
            Ok::<(), anyhow::Error>(())
        }
        .in_current_span()
    })
    .await?
    .map_err(Into::<anyhow::Error>::into);
    futures::future::try_join(a, b).await?;
    tracing::info!(
        "Finished uploading paths to queue runner directly. elapsed={:?}",
        before_upload.elapsed()
    );

    metrics.sub_uploading_path(nars_len);
    Ok(())
}

#[tracing::instrument(skip(client, store), err)]
async fn upload_nars_presigned(
    mut client: BuilderClient,
    upload_client: PresignedUploadClient,
    store: nix_utils::LocalStore,
    output_paths: &[nix_utils::StorePath],
    opts: crate::grpc::runner_v1::PresignedUploadOpts,
    build_id: &str,
    machine_id: &str,
) -> anyhow::Result<()> {
    use futures::stream::StreamExt as _;

    tracing::info!("Start uploading paths using presigned urls");
    let before_upload = Instant::now();

    let paths_to_upload = store
        .query_requisites(&output_paths.iter().collect::<Vec<_>>(), true)
        .await
        .unwrap_or_default();
    let paths_to_upload_ref = paths_to_upload.iter().collect::<Vec<_>>();
    let path_infos = Arc::new(store.query_path_infos(&paths_to_upload_ref).await);

    let mut nars = Vec::with_capacity(paths_to_upload.len());
    let mut stream = tokio_stream::iter(paths_to_upload.clone())
        .map(|path| {
            let store = store.clone();
            let path_infos = path_infos.clone();
            async move {
                let debug_info_ids = if opts.upload_debug_info {
                    binary_cache::get_debug_info_build_ids(&store, &path).await?
                } else {
                    Vec::new()
                };
                let Some(narhash) = path_infos.get(&path).map(|i| i.nar_hash.clone()) else {
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
            &store,
            &nix_utils::StorePath::new(&presigned_response.store_path),
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

#[tracing::instrument(skip(store, nar_path, presigned_response), err)]
async fn upload_single_nar_presigned(
    store: &nix_utils::LocalStore,
    nar_path: &nix_utils::StorePath,
    build_id: &str,
    machine_id: &str,
    presigned_response: &runner_v1::PresignedNarResponse,
    client: &mut BuilderClient,
    upload_client: &PresignedUploadClient,
) -> anyhow::Result<()> {
    let narinfo = binary_cache::path_to_narinfo(store, nar_path).await?;
    let nar_upload = presigned_response
        .nar_upload
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("nar_upload information is missing"))?;

    let presigned_request = binary_cache::PresignedUploadResponse {
        nar_url: presigned_response.nar_url.clone(),
        nar_upload: binary_cache::PresignedUpload::new(
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
        .process_presigned_request(store, narinfo, presigned_request)
        .await?;

    tracing::debug!(
        "Successfully uploaded presigned NAR for {} to {}",
        nar_path,
        updated_narinfo.url
    );

    if let (Some(file_hash), Some(file_size)) = (
        updated_narinfo.file_hash.as_ref(),
        updated_narinfo.file_size,
    ) {
        let completion_msg = runner_v1::PresignedUploadComplete {
            build_id: build_id.to_owned(),
            machine_id: machine_id.to_owned(),
            store_path: nar_path.base_name().to_owned(),
            url: updated_narinfo.url.clone(),
            compression: updated_narinfo.compression.as_str().to_owned(),
            file_hash: file_hash.clone(),
            file_size,
            nar_hash: updated_narinfo.nar_hash,
            nar_size: updated_narinfo.nar_size,
            references: updated_narinfo
                .references
                .iter()
                .map(|p| p.base_name().to_owned())
                .collect(),
            deriver: updated_narinfo.deriver.map(|p| p.base_name().to_owned()),
            ca: updated_narinfo.ca,
        };

        client
            .notify_presigned_upload_complete(completion_msg)
            .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(store, drv_info), fields(%drv), ret(level = tracing::Level::DEBUG), err)]
async fn new_success_build_result_info(
    store: nix_utils::LocalStore,
    machine_id: uuid::Uuid,
    drv: &nix_utils::StorePath,
    drv_info: nix_utils::Derivation,
    timings: BuildTimings,
    build_id: String,
) -> anyhow::Result<BuildResultInfo> {
    let outputs = &drv_info
        .outputs
        .iter()
        .filter_map(|o| o.path.as_ref())
        .collect::<Vec<_>>();
    let pathinfos = store.query_path_infos(outputs).await;
    let nix_support = Box::pin(shared::parse_nix_support_from_outputs(
        &store,
        &drv_info.outputs,
    ))
    .await?;

    let mut build_outputs = vec![];
    for o in drv_info.outputs {
        build_outputs.push(Output {
            output: Some(match o.path {
                Some(p) => {
                    if let Some(info) = pathinfos.get(&p) {
                        output::Output::Withpath(OutputWithPath {
                            name: o.name,
                            closure_size: store.compute_closure_size(&p).await,
                            path: p.into_base_name(),
                            nar_size: info.nar_size,
                            nar_hash: info.nar_hash.clone(),
                        })
                    } else {
                        output::Output::Nameonly(OutputNameOnly { name: o.name })
                    }
                }
                None => output::Output::Nameonly(OutputNameOnly { name: o.name }),
            }),
        });
    }

    Ok(BuildResultInfo {
        build_id,
        machine_id: machine_id.to_string(),
        import_time_ms: u64::try_from(timings.import_elapsed.as_millis())?,
        build_time_ms: u64::try_from(timings.build_elapsed.as_millis())?,
        upload_time_ms: u64::try_from(timings.upload_elapsed.as_millis())?,
        result_state: BuildResultState::Success as i32,
        outputs: build_outputs,
        nix_support: Some(NixSupport {
            metrics: nix_support
                .metrics
                .into_iter()
                .map(|m| BuildMetric {
                    path: m.path,
                    name: m.name,
                    unit: m.unit,
                    value: m.value,
                })
                .collect(),
            failed: nix_support.failed,
            hydra_release_name: nix_support.hydra_release_name,
            products: nix_support
                .products
                .into_iter()
                .map(|p| BuildProduct {
                    path: p.path,
                    default_path: p.default_path,
                    r#type: p.r#type,
                    subtype: p.subtype,
                    name: p.name,
                    is_regular: p.is_regular,
                    sha256hash: p.sha256hash,
                    file_size: p.file_size,
                })
                .collect(),
        }),
    })
}
