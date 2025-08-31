use std::{
    sync::{Arc, atomic},
    time::Instant,
};

use ahash::AHashMap;
use anyhow::Context;
use futures::TryFutureExt as _;
use tonic::Request;
use tracing::Instrument;

use crate::runner_v1::{BuildResultState, StepStatus, StepUpdate};
use nix_utils::BaseStore as _;

#[derive(thiserror::Error, Debug)]
#[allow(clippy::enum_variant_names)]
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

pub struct BuildInfo {
    handle: tokio::task::JoinHandle<()>,
}

impl BuildInfo {
    fn abort(&self) {
        self.handle.abort();
    }
}

pub struct Config {
    pub ping_interval: u64,
    pub speed_factor: f32,
    pub max_jobs: u32,
    pub tmp_avail_threshold: f32,
    pub store_avail_threshold: f32,
    pub load1_threshold: f32,
    pub cpu_psi_threshold: f32,
    pub mem_psi_threshold: f32,
    pub io_psi_threshold: Option<f32>,
    pub gcroots: std::path::PathBuf,
    pub systems: Option<Vec<String>>,
    pub supported_features: Option<Vec<String>>,
    pub mandatory_features: Option<Vec<String>>,
    pub use_substitutes: bool,
}

pub struct State {
    id: uuid::Uuid,

    active_builds: parking_lot::RwLock<AHashMap<nix_utils::StorePath, Arc<BuildInfo>>>,

    pub config: Config,
    pub store: nix_utils::LocalStore,

    pub max_concurrent_downloads: atomic::AtomicU32,
}

#[derive(Debug)]
struct Gcroot {
    root: std::path::PathBuf,
}

impl Gcroot {
    pub fn new(path: std::path::PathBuf) -> std::io::Result<Self> {
        std::fs::create_dir_all(&path)?;
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
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

impl State {
    pub fn new(args: super::config::Args) -> anyhow::Result<Arc<Self>> {
        let store = nix_utils::LocalStore::init();
        nix_utils::set_verbosity(1);

        let logname = std::env::var("LOGNAME").context("LOGNAME not set")?;
        let nix_state_dir = std::env::var("NIX_STATE_DIR").unwrap_or("/nix/var/nix/".to_owned());
        let gcroots = std::path::PathBuf::from(nix_state_dir)
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots");
        std::fs::create_dir_all(&gcroots)?;

        Ok(Arc::new(Self {
            id: uuid::Uuid::new_v4(),
            active_builds: parking_lot::RwLock::new(AHashMap::new()),
            config: Config {
                ping_interval: args.ping_interval,
                speed_factor: args.speed_factor,
                max_jobs: args.max_jobs,
                tmp_avail_threshold: args.tmp_avail_threshold,
                store_avail_threshold: args.store_avail_threshold,
                load1_threshold: args.load1_threshold,
                cpu_psi_threshold: args.cpu_psi_threshold,
                mem_psi_threshold: args.mem_psi_threshold,
                io_psi_threshold: args.io_psi_threshold,
                gcroots,
                systems: args.systems,
                supported_features: args.supported_features,
                mandatory_features: args.mandatory_features,
                use_substitutes: args.use_substitutes,
            },
            store,
            max_concurrent_downloads: 5.into(),
        }))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_join_message(&self) -> anyhow::Result<crate::runner_v1::JoinMessage> {
        let sys = crate::system::BaseSystemInfo::new()?;

        let join = crate::runner_v1::JoinMessage {
            machine_id: self.id.to_string(),
            systems: if let Some(s) = &self.config.systems {
                s.clone()
            } else {
                let mut out = Vec::with_capacity(8);
                out.push(nix_utils::get_this_system());
                out.extend(nix_utils::get_extra_platforms());
                out
            },
            hostname: gethostname::gethostname()
                .into_string()
                .map_err(|_| anyhow::anyhow!("Couldn't convert hostname to string"))?,
            cpu_count: u32::try_from(sys.cpu_count)?,
            bogomips: sys.bogomips,
            speed_factor: self.config.speed_factor,
            max_jobs: self.config.max_jobs,
            tmp_avail_threshold: self.config.tmp_avail_threshold,
            store_avail_threshold: self.config.store_avail_threshold,
            load1_threshold: self.config.load1_threshold,
            cpu_psi_threshold: self.config.cpu_psi_threshold,
            mem_psi_threshold: self.config.mem_psi_threshold,
            io_psi_threshold: self.config.io_psi_threshold,
            total_mem: sys.total_memory,
            supported_features: if let Some(s) = &self.config.supported_features {
                s.clone()
            } else {
                nix_utils::get_system_features()
            },
            mandatory_features: self.config.mandatory_features.clone().unwrap_or_default(),
            cgroups: nix_utils::get_use_cgroups(),
        };

        log::info!("Builder systems={:?}", join.systems);
        log::info!("Builder supported_features={:?}", join.supported_features);
        log::info!("Builder mandatory_features={:?}", join.mandatory_features);
        log::info!("Builder use_cgroups={:?}", join.cgroups);

        Ok(join)
    }

    #[tracing::instrument(skip(self), err)]
    pub fn get_ping_message(&self) -> anyhow::Result<crate::runner_v1::PingMessage> {
        let sysinfo = crate::system::SystemLoad::new()?;

        Ok(crate::runner_v1::PingMessage {
            machine_id: self.id.to_string(),
            load1: sysinfo.load_avg_1,
            load5: sysinfo.load_avg_5,
            load15: sysinfo.load_avg_15,
            mem_usage: sysinfo.mem_usage,
            pressure: sysinfo.pressure.map(|p| crate::runner_v1::PressureState {
                cpu_some: p.cpu_some.map(Into::into),
                mem_some: p.mem_some.map(Into::into),
                mem_full: p.mem_full.map(Into::into),
                io_some: p.io_some.map(Into::into),
                io_full: p.io_full.map(Into::into),
                irq_full: p.irq_full.map(Into::into),
            }),
            tmp_free_percent: sysinfo.tmp_free_percent,
            store_free_percent: sysinfo.store_free_percent,
        })
    }

    #[tracing::instrument(skip(self, client, m), fields(drv=%m.drv))]
    pub fn schedule_build(
        self: Arc<Self>,
        mut client: crate::runner_v1::runner_service_client::RunnerServiceClient<
            tonic::transport::Channel,
        >,
        m: crate::runner_v1::BuildMessage,
    ) {
        let drv = nix_utils::StorePath::new(&m.drv);
        if self.contains_build(&drv) {
            return;
        }
        log::info!("Building {drv}");

        let task_handle = tokio::spawn({
            let self_ = self.clone();
            let drv = drv.clone();
            async move {
                let mut import_elapsed = std::time::Duration::from_millis(0);
                let mut build_elapsed = std::time::Duration::from_millis(0);
                match self_
                    .process_build(client.clone(), m, &mut import_elapsed, &mut build_elapsed)
                    .await
                {
                    Ok(()) => {
                        log::info!("Successfully completed build process for {drv}");
                        self_.remove_build(&drv);
                    }
                    Err(e) => {
                        log::error!("Build of {drv} failed with {e}");
                        self_.remove_build(&drv);
                        let failed_build = crate::runner_v1::BuildResultInfo {
                            machine_id: self_.id.to_string(),
                            drv: drv.into_base_name(),
                            import_time_ms: u64::try_from(import_elapsed.as_millis())
                                .unwrap_or_default(),
                            build_time_ms: u64::try_from(build_elapsed.as_millis())
                                .unwrap_or_default(),
                            result_state: BuildResultState::from(e) as i32,
                            outputs: vec![],
                            nix_support: None,
                        };

                        for i in 0..3 {
                            match client.complete_build(failed_build.clone()).await {
                                Ok(_) => break,
                                Err(e) => {
                                    if i == 2 {
                                        log::error!("Failed to submit build failure info: {e}");
                                    } else {
                                        log::error!(
                                            "Failed to submit build failure info (retrying ... i={i}): {e}"
                                        );
                                        // TODO: backoff
                                        tokio::time::sleep(tokio::time::Duration::from_secs(1))
                                            .await;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        });

        self.insert_new_build(
            drv,
            BuildInfo {
                handle: task_handle,
            },
        );
    }

    fn contains_build(&self, drv: &nix_utils::StorePath) -> bool {
        let active = self.active_builds.read();
        active.contains_key(drv)
    }

    fn insert_new_build(&self, drv: nix_utils::StorePath, b: BuildInfo) {
        {
            let mut active = self.active_builds.write();
            active.insert(drv, Arc::new(b));
        }
        self.publish_builds_to_sd_notify();
    }

    fn remove_build(&self, drv: &nix_utils::StorePath) -> Option<Arc<BuildInfo>> {
        let b = {
            let mut active = self.active_builds.write();
            active.remove(drv)
        };
        self.publish_builds_to_sd_notify();
        b
    }

    #[tracing::instrument(skip(self, m), fields(drv=%m.drv))]
    pub fn abort_build(&self, m: &crate::runner_v1::AbortMessage) {
        if let Some(b) = self.remove_build(&nix_utils::StorePath::new(&m.drv)) {
            b.abort();
        }
    }

    pub fn abort_all_active_builds(&self) {
        let mut active = self.active_builds.write();
        for b in active.values() {
            b.abort();
        }
        active.clear();
    }

    #[tracing::instrument(skip(self, client, m), fields(drv=%m.drv), err)]
    #[allow(clippy::too_many_lines)]
    async fn process_build(
        &self,
        mut client: crate::runner_v1::runner_service_client::RunnerServiceClient<
            tonic::transport::Channel,
        >,
        m: crate::runner_v1::BuildMessage,
        import_elapsed: &mut std::time::Duration,
        build_elapsed: &mut std::time::Duration,
    ) -> Result<(), JobFailure> {
        // we dont use anyhow here because we manually need to write the correct build status
        // to the queue runner.
        use tokio_stream::StreamExt as _;

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

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                machine_id: machine_id.to_string(),
                drv: drv.base_name().to_owned(),
                step_status: StepStatus::SeningInputs as i32,
            })
            .await;
        let requisites = client
            .fetch_drv_requisites(crate::runner_v1::FetchRequisitesRequest {
                path: resolved_drv.as_ref().unwrap_or(&drv).base_name().to_owned(),
                include_outputs: false,
            })
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .into_inner()
            .requisites;

        import_requisites(
            &mut client,
            self.store.clone(),
            &gcroot,
            resolved_drv.as_ref().unwrap_or(&drv),
            requisites
                .into_iter()
                .map(|s| nix_utils::StorePath::new(&s)),
            usize::try_from(
                self.max_concurrent_downloads
                    .load(atomic::Ordering::Relaxed),
            )
            .unwrap_or(5),
            self.config.use_substitutes,
        )
        .await
        .map_err(JobFailure::Import)?;
        *import_elapsed = before_import.elapsed();

        // Resolved drv and drv output paths are the same
        let drv_info = nix_utils::query_drv(&drv)
            .await
            .map_err(|e| JobFailure::Import(e.into()))?
            .ok_or(JobFailure::Import(anyhow::anyhow!("drv not found")))?;

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                machine_id: machine_id.to_string(),
                drv: drv.base_name().to_owned(),
                step_status: StepStatus::Building as i32,
            })
            .await;
        let before_build = Instant::now();
        let (mut child, mut log_output) = nix_utils::realise_drv(
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
                    Ok(chunk) => yield crate::runner_v1::LogChunk {
                        drv: drv2.base_name().to_owned(),
                        data: format!("{chunk}\n").into(),
                    },
                    Err(e) => {
                        log::error!("Failed to write log chunk to queue-runner: {e}");
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
            nix_utils::add_root(&gcroot.root, o);
        }

        *build_elapsed = before_build.elapsed();
        log::info!("Finished building {drv}");

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                machine_id: machine_id.to_string(),
                drv: drv.base_name().to_owned(),
                step_status: StepStatus::ReceivingOutputs as i32,
            })
            .await;
        upload_nars(client.clone(), self.store.clone(), output_paths)
            .await
            .map_err(JobFailure::Upload)?;

        let _ = client // we ignore the error here, as this step status has no prio
            .build_step_update(StepUpdate {
                machine_id: machine_id.to_string(),
                drv: drv.base_name().to_owned(),
                step_status: StepStatus::PostProcessing as i32,
            })
            .await;
        let build_results = new_success_build_result_info(
            self.store.clone(),
            machine_id,
            &drv,
            drv_info,
            *import_elapsed,
            *build_elapsed,
        )
        .await
        .map_err(JobFailure::PostProcessing)?;
        // This part is stupid, if writing doesnt work, we try to write a failure, maybe that works
        client
            .complete_build(build_results)
            .await
            .map_err(|e| JobFailure::PostProcessing(e.into()))?;

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
                .keys()
                .map(|b| b.base_name().to_owned())
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

    pub fn clear_gcroots(&self) -> std::io::Result<()> {
        std::fs::remove_dir_all(&self.config.gcroots)?;
        std::fs::create_dir_all(&self.config.gcroots)?;
        Ok(())
    }
}

#[tracing::instrument(fields(%gcroot, %path))]
async fn filter_missing(
    gcroot: &Gcroot,
    path: nix_utils::StorePath,
) -> Option<nix_utils::StorePath> {
    if nix_utils::check_if_storepath_exists(&path).await {
        nix_utils::add_root(&gcroot.root, &path);
        None
    } else {
        Some(path)
    }
}

async fn substitute_paths(
    paths: &[&nix_utils::StorePath],
    build_opts: &nix_utils::BuildOptions,
) -> anyhow::Result<()> {
    let (mut child, _) = nix_utils::realise_drvs(paths, build_opts, false).await?;
    nix_utils::validate_statuscode(child.wait().await?)?;
    Ok(())
}

#[tracing::instrument(skip(client, store), fields(%gcroot), err)]
async fn import_paths(
    mut client: crate::runner_v1::runner_service_client::RunnerServiceClient<
        tonic::transport::Channel,
    >,
    store: nix_utils::LocalStore,
    gcroot: &Gcroot,
    paths: Vec<nix_utils::StorePath>,
    filter: bool,
    use_substitutes: Option<&nix_utils::BuildOptions>,
) -> anyhow::Result<()> {
    use futures::StreamExt as _;

    let paths = if filter {
        futures::StreamExt::map(tokio_stream::iter(paths), |p| filter_missing(gcroot, p))
            .buffered(10)
            .filter_map(|o| async { o })
            .collect::<Vec<_>>()
            .await
    } else {
        paths
    };
    let paths = if let Some(build_opts) = use_substitutes {
        // we can ignore the error
        let _ = substitute_paths(&paths.iter().collect::<Vec<_>>(), build_opts).await;
        let paths =
            futures::StreamExt::map(tokio_stream::iter(paths), |p| filter_missing(gcroot, p))
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

    log::debug!("Start importing paths");
    let stream = client
        .stream_files(crate::runner_v1::StorePaths {
            paths: paths.iter().map(|p| p.base_name().to_owned()).collect(),
        })
        .await?
        .into_inner();

    store
        .import_paths(
            tokio_stream::StreamExt::map(stream, |s| {
                s.map(|v| v.chunk.into())
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, e))
            }),
            false,
        )
        .await?;
    log::debug!("Finished importing paths");

    for p in paths {
        nix_utils::add_root(&gcroot.root, &p);
    }
    Ok(())
}

#[tracing::instrument(skip(client, store, requisites), fields(%gcroot, %drv), err)]
async fn import_requisites<T: IntoIterator<Item = nix_utils::StorePath>>(
    client: &mut crate::runner_v1::runner_service_client::RunnerServiceClient<
        tonic::transport::Channel,
    >,
    store: nix_utils::LocalStore,
    gcroot: &Gcroot,
    drv: &nix_utils::StorePath,
    requisites: T,
    max_concurrent_downloads: usize,
    use_substitutes: bool,
) -> anyhow::Result<()> {
    use futures::stream::StreamExt as _;

    let requisites = futures::StreamExt::map(tokio_stream::iter(requisites), |p| {
        filter_missing(gcroot, p)
    })
    .buffered(50)
    .filter_map(|o| async { o })
    .collect::<Vec<_>>()
    .await;

    let use_substitutes = if use_substitutes {
        Some(nix_utils::BuildOptions::substitute_only())
    } else {
        None
    };

    let (input_drvs, input_srcs): (Vec<_>, Vec<_>) = requisites
        .into_iter()
        .partition(nix_utils::StorePath::is_drv);

    for srcs in input_srcs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            store.clone(),
            gcroot,
            srcs.to_vec(),
            true,
            use_substitutes.as_ref(),
        )
        .await?;
    }

    for drvs in input_drvs.chunks(max_concurrent_downloads) {
        import_paths(
            client.clone(),
            store.clone(),
            gcroot,
            drvs.to_vec(),
            true,
            None, // never use substitute for drvs
        )
        .await?;
    }

    let full_requisites = client
        .clone()
        .fetch_drv_requisites(crate::runner_v1::FetchRequisitesRequest {
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
        filter_missing(gcroot, p)
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
            gcroot,
            other.to_vec(),
            false,
            use_substitutes.as_ref(),
        )
        .await?;
    }

    Ok(())
}

#[tracing::instrument(skip(client, store), err)]
async fn upload_nars(
    mut client: crate::runner_v1::runner_service_client::RunnerServiceClient<
        tonic::transport::Channel,
    >,
    store: nix_utils::LocalStore,
    nars: Vec<nix_utils::StorePath>,
) -> anyhow::Result<()> {
    log::debug!("Start uploading paths");
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<crate::runner_v1::NarData>();
    let closure = move |data: &[u8]| {
        let data = Vec::from(data);
        tx.send(crate::runner_v1::NarData { chunk: data }).is_ok()
    };
    let a = client
        .build_result(tokio_stream::wrappers::UnboundedReceiverStream::new(rx))
        .map_err(Into::<anyhow::Error>::into);

    let b = tokio::task::spawn_blocking(move || {
        async move {
            store.export_paths(&nars, closure)?;
            log::debug!("Finished exporting paths");
            Ok::<(), anyhow::Error>(())
        }
        .in_current_span()
    })
    .await?
    .map_err(Into::<anyhow::Error>::into);
    futures::future::try_join(a, b).await?;
    log::debug!("Finished uploading paths");
    Ok(())
}

#[tracing::instrument(skip(store, drv_info), fields(%drv), ret(level = tracing::Level::DEBUG), err)]
async fn new_success_build_result_info(
    store: nix_utils::LocalStore,
    machine_id: uuid::Uuid,
    drv: &nix_utils::StorePath,
    drv_info: nix_utils::Derivation,
    import_elapsed: std::time::Duration,
    build_elapsed: std::time::Duration,
) -> anyhow::Result<crate::runner_v1::BuildResultInfo> {
    let outputs = &drv_info
        .outputs
        .iter()
        .filter_map(|o| o.path.as_ref())
        .collect::<Vec<_>>();
    let pathinfos = store.query_path_infos(outputs);

    let nix_support = shared::parse_nix_support_from_outputs(&drv_info.outputs).await?;
    Ok(crate::runner_v1::BuildResultInfo {
        machine_id: machine_id.to_string(),
        drv: drv.base_name().to_owned(),
        import_time_ms: u64::try_from(import_elapsed.as_millis())?,
        build_time_ms: u64::try_from(build_elapsed.as_millis())?,
        result_state: BuildResultState::Success as i32,
        outputs: drv_info
            .outputs
            .into_iter()
            .map(|o| crate::runner_v1::Output {
                output: Some(match o.path {
                    Some(p) => {
                        if let Some(info) = pathinfos.get(&p) {
                            crate::runner_v1::output::Output::Withpath(
                                crate::runner_v1::OutputWithPath {
                                    name: o.name,
                                    closure_size: store.compute_closure_size(&p),
                                    path: p.into_base_name(),
                                    nar_size: info.nar_size,
                                    nar_hash: info.nar_hash.clone(),
                                },
                            )
                        } else {
                            crate::runner_v1::output::Output::Nameonly(
                                crate::runner_v1::OutputNameOnly { name: o.name },
                            )
                        }
                    }
                    None => crate::runner_v1::output::Output::Nameonly(
                        crate::runner_v1::OutputNameOnly { name: o.name },
                    ),
                }),
            })
            .collect(),
        nix_support: Some(crate::runner_v1::NixSupport {
            metrics: nix_support
                .metrics
                .into_iter()
                .map(|m| crate::runner_v1::BuildMetric {
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
                .map(|p| crate::runner_v1::BuildProduct {
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
