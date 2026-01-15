use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use hashbrown::{HashMap, HashSet};

use super::{Jobset, JobsetID, Step};
use db::models::{BuildID, BuildStatus};
use nix_utils::BaseStore as _;

pub type AtomicBuildID = AtomicI32;

#[derive(Debug)]
pub struct Build {
    pub id: BuildID,
    pub drv_path: nix_utils::StorePath,
    pub outputs: HashMap<String, nix_utils::StorePath>,
    pub jobset_id: JobsetID,
    pub name: String,
    pub timestamp: jiff::Timestamp,
    pub max_silent_time: i32,
    pub timeout: i32,
    pub local_priority: i32,
    pub global_priority: AtomicI32,

    toplevel: arc_swap::ArcSwapOption<Step>,
    pub jobset: Arc<Jobset>,

    finished_in_db: AtomicBool,
}

impl PartialEq for Build {
    fn eq(&self, other: &Self) -> bool {
        self.drv_path == other.drv_path
    }
}

impl Eq for Build {}

impl std::hash::Hash for Build {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        // ensure that drv_path is never mutable
        // as we set Build as ignore-interior-mutability
        self.drv_path.hash(state);
    }
}

impl Build {
    #[must_use]
    pub fn new_debug(drv_path: &nix_utils::StorePath) -> Arc<Self> {
        Arc::new(Self {
            id: BuildID::MAX,
            drv_path: drv_path.to_owned(),
            outputs: HashMap::with_capacity(6),
            jobset_id: JobsetID::MAX,
            name: "debug".into(),
            timestamp: jiff::Timestamp::now(),
            max_silent_time: i32::MAX,
            timeout: i32::MAX,
            local_priority: 1000,
            global_priority: 1000.into(),
            toplevel: arc_swap::ArcSwapOption::from(None),
            jobset: Arc::new(Jobset::new(JobsetID::MAX, "debug", "debug")),
            finished_in_db: false.into(),
        })
    }

    #[tracing::instrument(skip(v, jobset), err)]
    pub fn new(v: db::models::Build, jobset: Arc<Jobset>) -> anyhow::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            id: v.id,
            drv_path: nix_utils::StorePath::new(&v.drvpath),
            outputs: HashMap::with_capacity(6),
            jobset_id: v.jobset_id,
            name: v.job,
            timestamp: jiff::Timestamp::from_second(v.timestamp)?,
            max_silent_time: v.maxsilent.unwrap_or(3600),
            timeout: v.timeout.unwrap_or(36000),
            local_priority: v.priority,
            global_priority: v.globalpriority.into(),
            toplevel: arc_swap::ArcSwapOption::from(None),
            jobset,
            finished_in_db: false.into(),
        }))
    }

    #[inline]
    pub fn full_job_name(&self) -> String {
        format!(
            "{}:{}:{}",
            self.jobset.project_name, self.jobset.name, self.name
        )
    }

    #[inline]
    pub fn get_finished_in_db(&self) -> bool {
        self.finished_in_db.load(Ordering::SeqCst)
    }

    #[inline]
    pub fn set_finished_in_db(&self, v: bool) {
        self.finished_in_db.store(v, Ordering::SeqCst);
    }

    #[inline]
    pub fn set_toplevel_step(&self, step: Arc<Step>) {
        self.toplevel.store(Some(step));
    }

    pub fn propagate_priorities(&self) {
        let mut queued = HashSet::new();
        let mut todo = std::collections::VecDeque::new();
        {
            let toplevel = self.toplevel.load();
            if let Some(toplevel) = toplevel.as_ref() {
                todo.push_back(toplevel.clone());
            }
        }

        while let Some(step) = todo.pop_front() {
            step.atomic_state.highest_global_priority.store(
                std::cmp::max(
                    step.atomic_state
                        .highest_global_priority
                        .load(Ordering::Relaxed),
                    self.global_priority.load(Ordering::Relaxed),
                ),
                Ordering::Relaxed,
            );
            step.atomic_state.highest_local_priority.store(
                std::cmp::max(
                    step.atomic_state
                        .highest_local_priority
                        .load(Ordering::Relaxed),
                    self.local_priority,
                ),
                Ordering::Relaxed,
            );
            step.atomic_state.lowest_build_id.store(
                std::cmp::min(
                    step.atomic_state.lowest_build_id.load(Ordering::Relaxed),
                    self.id,
                ),
                Ordering::Relaxed,
            );
            step.add_jobset(self.jobset.clone());
            for dep in step.get_all_deps_not_queued(&queued) {
                queued.insert(dep.clone());
                todo.push_back(dep);
            }
        }
    }
}

#[derive(Debug)]
pub enum BuildResultState {
    Success,
    BuildFailure,
    PreparingFailure,
    ImportFailure,
    UploadFailure,
    PostProcessingFailure,
    Aborted,
    Cancelled,
}

impl From<crate::server::grpc::runner_v1::BuildResultState> for BuildResultState {
    fn from(v: crate::server::grpc::runner_v1::BuildResultState) -> Self {
        match v {
            crate::server::grpc::runner_v1::BuildResultState::BuildFailure => Self::BuildFailure,
            crate::server::grpc::runner_v1::BuildResultState::Success => Self::Success,
            crate::server::grpc::runner_v1::BuildResultState::PreparingFailure => {
                Self::PreparingFailure
            }
            crate::server::grpc::runner_v1::BuildResultState::ImportFailure => Self::ImportFailure,
            crate::server::grpc::runner_v1::BuildResultState::UploadFailure => Self::UploadFailure,
            crate::server::grpc::runner_v1::BuildResultState::PostProcessingFailure => {
                Self::PostProcessingFailure
            }
        }
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone)]
pub struct RemoteBuild {
    pub step_status: BuildStatus,
    pub can_retry: bool,           // for bsAborted
    pub is_cached: bool,           // for bsSucceed
    pub can_cache: bool,           // for bsFailed
    pub error_msg: Option<String>, // for bsAborted

    times_built: i32,
    is_non_deterministic: bool,

    start_time: Option<jiff::Timestamp>,
    stop_time: Option<jiff::Timestamp>,

    overhead: i32,
    pub log_file: String,
}

impl Default for RemoteBuild {
    fn default() -> Self {
        Self::new()
    }
}

impl RemoteBuild {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            step_status: BuildStatus::Aborted,
            can_retry: false,
            is_cached: false,
            can_cache: false,
            error_msg: None,
            times_built: 0,
            is_non_deterministic: false,
            start_time: None,
            stop_time: None,
            overhead: 0,
            log_file: String::new(),
        }
    }

    #[must_use]
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    pub fn get_total_step_time_ms(&self) -> u64 {
        if let (Some(start_time), Some(stop_time)) = (self.start_time, self.stop_time) {
            (stop_time - start_time)
                .total(jiff::Unit::Millisecond)
                .unwrap_or_default()
                .abs() as u64
        } else {
            0
        }
    }

    pub const fn update_with_result_state(&mut self, state: &BuildResultState) {
        match state {
            BuildResultState::BuildFailure => {
                self.can_retry = false;
            }
            BuildResultState::Success => (),
            BuildResultState::PreparingFailure
            | BuildResultState::ImportFailure
            | BuildResultState::UploadFailure
            | BuildResultState::PostProcessingFailure => {
                self.can_retry = true;
            }
            BuildResultState::Aborted => {
                self.can_retry = true;
                self.step_status = BuildStatus::Aborted;
            }
            BuildResultState::Cancelled => {
                self.can_retry = true;
                self.step_status = BuildStatus::Cancelled;
            }
        }
    }

    pub const fn set_start_and_stop(&mut self, v: jiff::Timestamp) {
        self.start_time = Some(v);
        self.stop_time = Some(v);
    }

    pub fn set_start_time_now(&mut self) {
        self.start_time = Some(jiff::Timestamp::now());
    }

    pub fn set_stop_time_now(&mut self) {
        self.stop_time = Some(jiff::Timestamp::now());
    }

    #[must_use]
    pub const fn has_start_time(&self) -> bool {
        self.start_time.is_some()
    }

    pub fn get_start_time_as_i32(&self) -> Result<i32, std::num::TryFromIntError> {
        // TODO: migrate to 64 bit timestamps
        i32::try_from(
            self.start_time
                .map(jiff::Timestamp::as_second)
                .unwrap_or_default(),
        )
    }

    #[must_use]
    pub const fn has_stop_time(&self) -> bool {
        self.stop_time.is_some()
    }

    pub fn get_stop_time_as_i32(&self) -> Result<i32, std::num::TryFromIntError> {
        // TODO: migrate to 64 bit timestamps
        i32::try_from(
            self.stop_time
                .map(jiff::Timestamp::as_second)
                .unwrap_or_default(),
        )
    }

    #[must_use]
    pub const fn get_overhead(&self) -> Option<i32> {
        if self.overhead != 0 {
            Some(self.overhead)
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get_times_built(&self) -> Option<i32> {
        if self.times_built != 0 {
            Some(self.times_built)
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get_is_non_deterministic(&self) -> Option<bool> {
        if self.times_built != 0 {
            Some(self.is_non_deterministic)
        } else {
            None
        }
    }

    pub fn set_overhead(&mut self, v: u128) -> Result<(), std::num::TryFromIntError> {
        self.overhead = i32::try_from(v)?;
        Ok(())
    }
}

pub struct BuildProduct {
    pub path: Option<nix_utils::StorePath>,
    pub default_path: Option<String>,

    pub r#type: String,
    pub subtype: String,
    pub name: String,

    pub is_regular: bool,

    pub sha256hash: Option<String>,
    pub file_size: Option<u64>,
}

impl From<db::models::OwnedBuildProduct> for BuildProduct {
    fn from(v: db::models::OwnedBuildProduct) -> Self {
        Self {
            path: v.path.map(|v| nix_utils::StorePath::new(&v)),
            default_path: v.defaultpath,
            r#type: v.r#type,
            subtype: v.subtype,
            name: v.name,
            is_regular: v.filesize.is_some(),
            sha256hash: v.sha256hash,
            #[allow(clippy::cast_sign_loss)]
            file_size: v.filesize.map(|v| v as u64),
        }
    }
}

impl From<crate::server::grpc::runner_v1::BuildProduct> for BuildProduct {
    fn from(v: crate::server::grpc::runner_v1::BuildProduct) -> Self {
        Self {
            path: Some(nix_utils::StorePath::new(&v.path)),
            default_path: Some(v.default_path),
            r#type: v.r#type,
            subtype: v.subtype,
            name: v.name,
            is_regular: v.is_regular,
            sha256hash: v.sha256hash,
            file_size: v.file_size,
        }
    }
}

impl From<shared::BuildProduct> for BuildProduct {
    fn from(v: shared::BuildProduct) -> Self {
        Self {
            path: Some(nix_utils::StorePath::new(&v.path)),
            default_path: Some(v.default_path),
            r#type: v.r#type,
            subtype: v.subtype,
            name: v.name,
            is_regular: v.is_regular,
            sha256hash: v.sha256hash,
            file_size: v.file_size,
        }
    }
}

pub struct BuildMetric {
    pub name: String,
    pub unit: Option<String>,
    pub value: f64,
}

impl From<db::models::OwnedBuildMetric> for BuildMetric {
    fn from(v: db::models::OwnedBuildMetric) -> Self {
        Self {
            name: v.name,
            unit: v.unit,
            value: v.value,
        }
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct BuildTimings {
    pub import_elapsed: std::time::Duration,
    pub build_elapsed: std::time::Duration,
    pub upload_elapsed: std::time::Duration,
}

impl BuildTimings {
    #[must_use]
    pub const fn new(import_time_ms: u64, build_time_ms: u64, upload_time_ms: u64) -> Self {
        Self {
            import_elapsed: std::time::Duration::from_millis(import_time_ms),
            build_elapsed: std::time::Duration::from_millis(build_time_ms),
            upload_elapsed: std::time::Duration::from_millis(upload_time_ms),
        }
    }

    #[must_use]
    pub const fn get_overhead(&self) -> u128 {
        self.import_elapsed.as_millis() + self.upload_elapsed.as_millis()
    }
}

pub struct BuildOutput {
    pub failed: bool,
    pub timings: BuildTimings,
    pub release_name: Option<String>,

    pub closure_size: u64,
    pub size: u64,

    pub products: Vec<BuildProduct>,
    pub outputs: HashMap<String, nix_utils::StorePath>,
    pub metrics: HashMap<String, BuildMetric>,
}

impl TryFrom<db::models::BuildOutput> for BuildOutput {
    type Error = anyhow::Error;

    fn try_from(v: db::models::BuildOutput) -> anyhow::Result<Self> {
        let build_status = BuildStatus::from_i32(
            v.buildstatus
                .ok_or_else(|| anyhow::anyhow!("buildstatus missing"))?,
        )
        .ok_or_else(|| anyhow::anyhow!("buildstatus did not map"))?;
        Ok(Self {
            failed: build_status != BuildStatus::Success,
            timings: BuildTimings::default(),
            release_name: v.releasename,
            #[allow(clippy::cast_sign_loss)]
            closure_size: v.closuresize.unwrap_or_default() as u64,
            #[allow(clippy::cast_sign_loss)]
            size: v.size.unwrap_or_default() as u64,
            products: vec![],
            outputs: HashMap::with_capacity(6),
            metrics: HashMap::with_capacity(10),
        })
    }
}

impl From<crate::server::grpc::runner_v1::BuildResultInfo> for BuildOutput {
    fn from(v: crate::server::grpc::runner_v1::BuildResultInfo) -> Self {
        let mut outputs = HashMap::with_capacity(6);
        let mut closure_size = 0;
        let mut nar_size = 0;

        for o in v.outputs {
            match o.output {
                Some(crate::server::grpc::runner_v1::output::Output::Nameonly(_)) => {
                    // We dont care about outputs that dont have a path,
                }
                Some(crate::server::grpc::runner_v1::output::Output::Withpath(o)) => {
                    outputs.insert(o.name, nix_utils::StorePath::new(&o.path));
                    closure_size += o.closure_size;
                    nar_size += o.nar_size;
                }
                None => (),
            }
        }
        let (failed, release_name, products, metrics) = if let Some(nix_support) = v.nix_support {
            (
                nix_support.failed,
                nix_support.hydra_release_name,
                nix_support.products,
                nix_support.metrics,
            )
        } else {
            (false, None, vec![], vec![])
        };

        Self {
            failed,
            timings: BuildTimings::new(v.import_time_ms, v.build_time_ms, v.upload_time_ms),
            release_name,
            closure_size,
            size: nar_size,
            products: products.into_iter().map(Into::into).collect(),
            outputs,
            metrics: metrics
                .into_iter()
                .map(|v| {
                    (
                        v.path,
                        BuildMetric {
                            name: v.name,
                            unit: v.unit,
                            value: v.value,
                        },
                    )
                })
                .collect(),
        }
    }
}

impl BuildOutput {
    #[tracing::instrument(skip(store, outputs), err)]
    pub async fn new(
        store: &nix_utils::LocalStore,
        outputs: Vec<nix_utils::DerivationOutput>,
    ) -> anyhow::Result<Self> {
        let flat_outputs = outputs
            .iter()
            .filter_map(|o| o.path.as_ref())
            .collect::<Vec<_>>();
        let pathinfos = store.query_path_infos(&flat_outputs).await;
        let nix_support = Box::pin(shared::parse_nix_support_from_outputs(store, &outputs)).await?;

        let mut outputs_map = HashMap::with_capacity(outputs.len());
        let mut closure_size = 0;
        let mut nar_size = 0;

        for o in outputs {
            if let Some(path) = o.path
                && let Some(info) = pathinfos.get(&path)
            {
                closure_size += store.compute_closure_size(&path).await;
                nar_size += info.nar_size;
                outputs_map.insert(o.name, path);
            }
        }

        Ok(Self {
            failed: nix_support.failed,
            timings: BuildTimings::default(),
            release_name: nix_support.hydra_release_name,
            closure_size,
            size: nar_size,
            products: nix_support.products.into_iter().map(Into::into).collect(),
            outputs: outputs_map,
            metrics: nix_support
                .metrics
                .into_iter()
                .map(|v| {
                    (
                        v.path,
                        BuildMetric {
                            name: v.name,
                            unit: v.unit,
                            value: v.value,
                        },
                    )
                })
                .collect(),
        })
    }
}

pub fn get_mark_build_sccuess_data<'a>(
    store: &nix_utils::LocalStore,
    b: &'a Arc<crate::state::Build>,
    res: &'a crate::state::BuildOutput,
) -> db::models::MarkBuildSuccessData<'a> {
    db::models::MarkBuildSuccessData {
        id: b.id,
        name: &b.name,
        project_name: &b.jobset.project_name,
        jobset_name: &b.jobset.name,
        finished_in_db: b.get_finished_in_db(),
        timestamp: b.timestamp.as_second(),
        failed: res.failed,
        closure_size: res.closure_size,
        size: res.size,
        release_name: res.release_name.as_deref(),
        outputs: res
            .outputs
            .iter()
            .map(|(name, path)| (name.clone(), store.print_store_path(path)))
            .collect(),
        products: res
            .products
            .iter()
            .map(|v| db::models::BuildProduct {
                r#type: &v.r#type,
                subtype: &v.subtype,
                filesize: v.file_size.and_then(|v| i64::try_from(v).ok()),
                sha256hash: v.sha256hash.as_deref(),
                path: v.path.as_ref().map(|p| store.print_store_path(p)),
                name: &v.name,
                defaultpath: v.default_path.as_deref(),
            })
            .collect(),
        metrics: res
            .metrics
            .iter()
            .map(|(name, m)| {
                (
                    name.as_str(),
                    db::models::BuildMetric {
                        name: &m.name,
                        unit: m.unit.as_deref(),
                        value: m.value,
                    },
                )
            })
            .collect(),
    }
}

#[derive(Clone)]
pub struct Builds {
    inner: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
}

impl Default for Builds {
    fn default() -> Self {
        Self::new()
    }
}

impl Builds {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(parking_lot::RwLock::new(HashMap::with_capacity(1000))),
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.read().len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.inner.read().is_empty()
    }

    #[must_use]
    pub fn clone_as_io(&self) -> Vec<crate::io::Build> {
        let builds = self.inner.read();
        builds.values().map(|v| v.clone().into()).collect()
    }

    pub fn update_priorities(&self, curr_ids: &HashMap<BuildID, i32>) {
        let mut builds = self.inner.write();
        builds.retain(|k, _| curr_ids.contains_key(k));
        for (id, build) in builds.iter() {
            let Some(new_priority) = curr_ids.get(id) else {
                // we should never get into this case because of the retain above
                continue;
            };

            if build.global_priority.load(Ordering::Relaxed) < *new_priority {
                tracing::info!("priority of build {id} increased");
                build
                    .global_priority
                    .store(*new_priority, Ordering::Relaxed);
                build.propagate_priorities();
            }
        }
    }

    pub fn insert_new_build(&self, build: Arc<Build>) {
        let mut builds = self.inner.write();
        builds.insert(build.id, build);
    }

    pub fn remove_by_id(&self, id: BuildID) {
        let mut builds = self.inner.write();
        builds.remove(&id);
    }
}
