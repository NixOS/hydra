use std::collections::BTreeMap;
use std::hash::Hash;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use hashbrown::{HashMap, HashSet};

use super::{Jobset, JobsetID, Step};
use db::models::{BuildID, BuildStatus};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::StorePath;

pub(super) type AtomicBuildID = AtomicI32;

#[derive(Debug)]
pub struct Build {
    pub id: BuildID,
    pub drv_path: StorePath,
    pub outputs: BTreeMap<OutputName, StorePath>,
    pub jobset_id: JobsetID,
    pub name: String,
    pub timestamp: jiff::Timestamp,
    pub max_silent_time: i32,
    pub timeout: i32,
    pub local_priority: i32,
    pub global_priority: AtomicI32,

    pub toplevel: arc_swap::ArcSwapOption<Step>,
    pub jobset: Arc<Jobset>,

    finished_in_db: AtomicBool,
}

impl PartialEq for Build {
    fn eq(&self, other: &Self) -> bool {
        self.drv_path == other.drv_path
    }
}

impl Eq for Build {}

impl Hash for Build {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        // ensure that drv_path is never mutable
        // as we set Build as ignore-interior-mutability
        Hash::hash(&self.drv_path, state);
    }
}

impl Build {
    #[must_use]
    pub fn new_debug(drv_path: &StorePath) -> Arc<Self> {
        Arc::new(Self {
            id: BuildID::MAX,
            drv_path: drv_path.to_owned(),
            outputs: BTreeMap::new(),
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
    pub fn new(v: db::models::Build, jobset: Arc<Jobset>) -> Result<Arc<Self>, jiff::Error> {
        Ok(Arc::new(Self {
            id: v.id,
            drv_path: v.drvpath,
            outputs: BTreeMap::new(),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildResultState {
    /// Result reported by the builder over gRPC.
    Completed(hydra_proto::BuildResultState),
    Aborted,
    Cancelled,
}

impl From<hydra_proto::BuildResultState> for BuildResultState {
    fn from(v: hydra_proto::BuildResultState) -> Self {
        Self::Completed(v)
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone)]
pub struct RemoteBuild {
    pub step_status: BuildStatus,
    /// for bsAborted
    pub can_retry: bool,
    /// for bsSucceed
    pub is_cached: bool,
    /// for bsFailed
    pub can_cache: bool,
    /// for bsAborted
    pub error_msg: Option<String>,

    times_built: i32,
    is_non_deterministic: bool,

    start_time: Option<jiff::Timestamp>,
    stop_time: Option<jiff::Timestamp>,

    overhead: i32,
    pub log_file: std::path::PathBuf,
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
            log_file: std::path::PathBuf::new(),
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

    const fn update_with_completed(&mut self, state: hydra_proto::BuildResultState) {
        match state {
            hydra_proto::BuildResultState::BuildFailure => {
                self.can_retry = false;
            }
            hydra_proto::BuildResultState::TimedOutFailure => {
                self.can_retry = false;
                self.step_status = BuildStatus::TimedOut;
            }
            hydra_proto::BuildResultState::LogLimitFailure => {
                self.can_retry = false;
                self.step_status = BuildStatus::LogLimitExceeded;
            }
            hydra_proto::BuildResultState::NarSizeLimitFailure => {
                self.can_retry = false;
                self.step_status = BuildStatus::NarSizeLimitExceeded;
            }
            hydra_proto::BuildResultState::Success => (),
            hydra_proto::BuildResultState::PreparingFailure
            | hydra_proto::BuildResultState::ImportFailure
            | hydra_proto::BuildResultState::UploadFailure
            | hydra_proto::BuildResultState::PostProcessingFailure => {
                self.can_retry = true;
                // Retryable: only genuine build failures are recorded as Failed.
                self.step_status = BuildStatus::Aborted;
            }
        }
    }

    pub const fn update_with_result_state(&mut self, state: BuildResultState) {
        match state {
            BuildResultState::Completed(s) => self.update_with_completed(s),
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

pub(crate) use nix_support::{BuildMetric, BuildProduct};

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

#[derive(Debug)]
pub struct BuildOutput {
    pub failed: bool,
    pub timings: BuildTimings,
    pub release_name: Option<String>,

    pub closure_size: u64,
    pub size: u64,

    pub products: Vec<BuildProduct>,
    pub outputs: BTreeMap<OutputName, StorePath>,
    pub metrics: BTreeMap<String, BuildMetric>,
}

/// Everything that can go wrong constructing a [`BuildOutput`], whether
/// parsing an incoming `BuildResultInfo`/db row or reading from the store.
#[derive(Debug, thiserror::Error)]
pub enum BuildOutputError {
    #[error("buildstatus missing")]
    BuildStatusMissing,

    #[error("buildstatus value did not map to a known status")]
    BuildStatusUnknown,

    #[error("output missing path")]
    OutputMissingPath,

    #[error("invalid output name")]
    OutputName(#[from] harmonia_store_path::StorePathNameError),

    #[error("nix daemon error")]
    Daemon(#[from] harmonia_store_remote::DaemonError),

    #[error("reading build output")]
    Io(#[from] std::io::Error),
}

impl TryFrom<db::models::BuildOutput> for BuildOutput {
    type Error = BuildOutputError;

    fn try_from(v: db::models::BuildOutput) -> Result<Self, Self::Error> {
        let build_status =
            BuildStatus::from_i32(v.buildstatus.ok_or(BuildOutputError::BuildStatusMissing)?)
                .ok_or(BuildOutputError::BuildStatusUnknown)?;
        Ok(Self {
            failed: build_status != BuildStatus::Success,
            timings: BuildTimings::default(),
            release_name: v.releasename,
            #[allow(clippy::cast_sign_loss)]
            closure_size: v.closuresize.unwrap_or_default() as u64,
            #[allow(clippy::cast_sign_loss)]
            size: v.size.unwrap_or_default() as u64,
            products: vec![],
            outputs: BTreeMap::new(),
            metrics: BTreeMap::new(),
        })
    }
}

impl BuildOutput {
    pub fn from_grpc(v: hydra_proto::BuildResultInfo) -> Result<Self, BuildOutputError> {
        let mut outputs = BTreeMap::new();
        let mut closure_size = 0;
        let mut nar_size = 0;
        let mut merged = nix_support::NixSupport::default();

        for (name, info) in v.output_infos {
            let path = info.path.ok_or(BuildOutputError::OutputMissingPath)?.0;
            closure_size += info.closure_size;
            nar_size += info.nar_size;
            outputs.insert(name.parse()?, path);
            if let Some(ns) = info.nix_support {
                let ns: nix_support::NixSupport = ns.into();
                merged.combine(ns);
            }
        }

        Ok(Self {
            failed: merged.failed,
            timings: BuildTimings::new(v.import_time_ms, v.build_time_ms, v.upload_time_ms),
            release_name: merged.hydra_release_name,
            closure_size,
            size: nar_size,
            products: merged.products,
            outputs,
            metrics: merged.metrics,
        })
    }
}

impl BuildOutput {
    #[tracing::instrument(skip(store, connector, real_store_dir, outputs), err)]
    pub async fn new(
        store: &daemon_client_utils::DaemonStoreReader,
        connector: &daemon_client_utils::DaemonConnector,
        real_store_dir: &std::path::Path,
        outputs: BTreeMap<OutputName, Option<StorePath>>,
    ) -> Result<Self, BuildOutputError> {
        let resolved: BTreeMap<_, _> = outputs
            .iter()
            .filter_map(|(name, path)| Some((name.clone(), path.as_ref()?.clone())))
            .collect();
        // Reuse one daemon connection across both query loops below.
        let mut conn = store.connect().await?;
        let mut pathinfos = BTreeMap::new();
        for path in resolved.values() {
            if let Some(info) = daemon_client_utils::query_path_info(&mut conn, path).await? {
                pathinfos.insert(path.clone(), info.info);
            }
        }
        let fs = nix_support::FilesystemOperations {
            real_store_dir: real_store_dir.to_owned(),
        };
        let per_output = Box::pin(nix_support::parse_nix_support_from_outputs(
            connector.store_dir(),
            &fs,
            &resolved,
        ))
        .await?;

        let mut merged = nix_support::NixSupport::default();
        for ns in per_output.into_values() {
            merged.combine(ns);
        }

        let mut outputs_map = BTreeMap::new();
        let mut closure_size = 0;
        let mut nar_size = 0;

        for (name, path) in resolved {
            if let Some(info) = pathinfos.get(&path) {
                closure_size += daemon_client_utils::compute_closure_size(&mut conn, &path).await;
                nar_size += info.nar_size;
                outputs_map.insert(name, path);
            }
        }

        Ok(Self {
            failed: merged.failed,
            timings: BuildTimings::default(),
            release_name: merged.hydra_release_name,
            closure_size,
            size: nar_size,
            products: merged.products,
            outputs: outputs_map,
            metrics: merged.metrics,
        })
    }
}

pub(super) fn get_mark_build_sccuess_data<'a>(
    b: &'a Arc<Build>,
    res: &'a BuildOutput,
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
            .map(|(name, path)| (name.clone(), path.clone()))
            .collect(),
        products: res.products.clone(),
        metrics: res.metrics.clone(),
    }
}

#[derive(Debug, Clone)]
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

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn transient_completed_failures_are_recorded_as_aborted() {
        for state in [
            hydra_proto::BuildResultState::PreparingFailure,
            hydra_proto::BuildResultState::ImportFailure,
            hydra_proto::BuildResultState::UploadFailure,
            hydra_proto::BuildResultState::PostProcessingFailure,
        ] {
            let mut result = RemoteBuild::new();
            result.step_status = BuildStatus::Failed;
            result.update_with_result_state(BuildResultState::Completed(state));
            assert!(result.can_retry);
            assert_eq!(result.step_status, BuildStatus::Aborted, "{state:?}");
        }
    }
}
