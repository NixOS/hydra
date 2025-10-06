#![allow(dead_code)]

use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering},
    },
};

use ahash::{AHashMap, AHashSet};
use chrono::TimeZone;

use super::jobset::{Jobset, JobsetID};
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
    pub timestamp: chrono::DateTime<chrono::Utc>,
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
    pub fn new_debug(drv_path: &nix_utils::StorePath) -> Arc<Self> {
        Arc::new(Self {
            id: BuildID::MAX,
            drv_path: drv_path.to_owned(),
            outputs: HashMap::new(),
            jobset_id: JobsetID::MAX,
            name: "debug".into(),
            timestamp: chrono::Utc::now(),
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
            outputs: HashMap::new(),
            jobset_id: v.jobset_id,
            name: v.job,
            timestamp: chrono::Utc.timestamp_opt(v.timestamp, 0).single().ok_or(
                anyhow::anyhow!("Failed to convert unix timestamp into chrono::UTC"),
            )?,
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
        let mut queued = AHashSet::new();
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
            {
                let mut state = step.state.write();
                state.jobsets.insert(self.jobset.clone());
            }

            let state = step.state.read();
            for dep in &state.deps {
                if !queued.contains(dep) {
                    queued.insert(dep.clone());
                    todo.push_back(dep.clone());
                }
            }
        }
    }
}

#[derive(Debug)]
pub struct StepAtomicState {
    created: AtomicBool,  // Whether the step has finished initialisation.
    pub tries: AtomicU32, // Number of times we've tried this step.
    pub highest_global_priority: AtomicI32, // The highest global priority of any build depending on this step.
    pub highest_local_priority: AtomicI32, // The highest local priority of any build depending on this step.

    pub lowest_build_id: AtomicBuildID, // The lowest ID of any build depending on this step.

    pub after: super::AtomicDateTime, // Point in time after which the step can be retried.
    pub runnable_since: super::AtomicDateTime, // The time at which this step became runnable.
    pub last_supported: super::AtomicDateTime, // The time that we last saw a machine that supports this step
}

impl StepAtomicState {
    pub fn new(
        after: chrono::DateTime<chrono::Utc>,
        runnable_since: chrono::DateTime<chrono::Utc>,
    ) -> Self {
        Self {
            created: false.into(),
            tries: 0.into(),
            highest_global_priority: 0.into(),
            highest_local_priority: 0.into(),
            lowest_build_id: BuildID::MAX.into(),
            after: super::AtomicDateTime::new(after),
            runnable_since: super::AtomicDateTime::new(runnable_since),
            last_supported: super::AtomicDateTime::default(),
        }
    }

    #[inline]
    pub fn get_created(&self) -> bool {
        self.created.load(Ordering::SeqCst)
    }

    #[inline]
    pub fn set_created(&self, v: bool) {
        self.created.store(v, Ordering::SeqCst);
    }
}

#[derive(Debug)]
pub struct StepState {
    pub deps: HashSet<Arc<Step>>, // The build steps on which this step depends.
    pub rdeps: Vec<Weak<Step>>,   // The build steps that depend on this step.
    pub builds: Vec<Weak<Build>>, // Builds that have this step as the top-level derivation.
    pub jobsets: AHashSet<Arc<Jobset>>, // Jobsets to which this step belongs. Used for determining scheduling priority.
}

impl StepState {
    pub fn new() -> Self {
        Self {
            deps: HashSet::new(),
            rdeps: Vec::new(),
            builds: Vec::new(),
            jobsets: AHashSet::new(),
        }
    }
}

#[derive(Debug)]
pub struct Step {
    drv_path: nix_utils::StorePath,
    drv: arc_swap::ArcSwapOption<nix_utils::Derivation>,

    runnable: AtomicBool,
    finished: AtomicBool,
    previous_failure: AtomicBool,
    pub atomic_state: StepAtomicState,
    pub state: parking_lot::RwLock<StepState>,
}

impl PartialEq for Step {
    fn eq(&self, other: &Self) -> bool {
        self.drv_path == other.drv_path
    }
}

impl Eq for Step {}

impl std::hash::Hash for Step {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        // ensure that drv_path is never mutable
        // as we set Step as ignore-interior-mutability
        self.drv_path.hash(state);
    }
}

impl Step {
    pub fn new(drv_path: nix_utils::StorePath) -> Arc<Self> {
        Arc::new(Self {
            drv_path,
            drv: arc_swap::ArcSwapOption::from(None),
            runnable: false.into(),
            finished: false.into(),
            previous_failure: false.into(),
            atomic_state: StepAtomicState::new(
                chrono::DateTime::<chrono::Utc>::from_timestamp_nanos(0),
                chrono::DateTime::<chrono::Utc>::from_timestamp_nanos(0),
            ),
            state: parking_lot::RwLock::new(StepState::new()),
        })
    }

    #[inline]
    pub fn get_drv_path(&self) -> &nix_utils::StorePath {
        &self.drv_path
    }

    #[inline]
    pub fn get_finished(&self) -> bool {
        self.finished.load(Ordering::SeqCst)
    }

    #[inline]
    pub fn set_finished(&self, v: bool) {
        self.finished.store(v, Ordering::SeqCst);
    }

    #[inline]
    pub fn get_previous_failure(&self) -> bool {
        self.previous_failure.load(Ordering::SeqCst)
    }

    #[inline]
    pub fn set_previous_failure(&self, v: bool) {
        self.previous_failure.store(v, Ordering::SeqCst);
    }

    #[inline]
    pub fn get_runnable(&self) -> bool {
        self.runnable.load(Ordering::SeqCst)
    }

    pub fn set_drv(&self, drv: nix_utils::Derivation) {
        self.drv.store(Some(Arc::new(drv)));
    }

    pub fn get_system(&self) -> Option<String> {
        let drv = self.drv.load_full();
        drv.as_ref().map(|drv| drv.system.clone())
    }

    pub fn get_input_drvs(&self) -> Option<Vec<String>> {
        let drv = self.drv.load_full();
        drv.as_ref().map(|drv| drv.input_drvs.clone())
    }

    pub fn get_after(&self) -> chrono::DateTime<chrono::Utc> {
        self.atomic_state.after.load()
    }

    pub fn set_after(&self, v: chrono::DateTime<chrono::Utc>) {
        self.atomic_state.after.store(v);
    }

    pub fn get_runnable_since(&self) -> chrono::DateTime<chrono::Utc> {
        self.atomic_state.runnable_since.load()
    }

    pub fn get_last_supported(&self) -> chrono::DateTime<chrono::Utc> {
        self.atomic_state.last_supported.load()
    }

    pub fn set_last_supported_now(&self) {
        self.atomic_state.last_supported.store(chrono::Utc::now());
    }

    pub fn get_outputs(&self) -> Option<Vec<nix_utils::DerivationOutput>> {
        let drv = self.drv.load_full();
        drv.as_ref().map(|drv| drv.outputs.clone())
    }

    pub fn get_required_features(&self) -> Vec<String> {
        let drv = self.drv.load_full();
        drv.as_ref()
            .map(|drv| {
                drv.env
                    .get_required_system_features()
                    .into_iter()
                    .map(ToOwned::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }

    #[tracing::instrument(skip(self, builds, steps))]
    pub fn get_dependents(
        self: &Arc<Self>,
        builds: &mut AHashSet<Arc<Build>>,
        steps: &mut AHashSet<Arc<Step>>,
    ) {
        if steps.contains(self) {
            return;
        }
        steps.insert(self.clone());

        let rdeps = {
            let state = self.state.read();
            for b in &state.builds {
                let Some(b) = b.upgrade() else { continue };

                if !b.get_finished_in_db() {
                    builds.insert(b);
                }
            }
            state.rdeps.clone()
        };

        for rdep in rdeps {
            let Some(rdep) = rdep.upgrade() else { continue };
            rdep.get_dependents(builds, steps);
        }
    }

    pub fn get_deps_size(&self) -> usize {
        let state = self.state.read();
        state.deps.len()
    }

    pub fn make_rdeps_runnable(&self) {
        if !self.get_finished() {
            return;
        }

        let state = self.state.read();
        for rdep in &state.rdeps {
            let Some(rdep) = rdep.upgrade() else {
                continue;
            };

            let mut runnable = false;
            {
                let mut rdep_state = rdep.state.write();
                rdep_state
                    .deps
                    .retain(|s| s.get_drv_path() != self.get_drv_path());
                if rdep_state.deps.is_empty() && rdep.atomic_state.get_created() {
                    runnable = true;
                }
            }

            if runnable {
                rdep.make_runnable();
            }
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn make_runnable(&self) {
        log::info!("step '{}' is now runnable", self.get_drv_path());
        debug_assert!(self.atomic_state.created.load(Ordering::SeqCst));
        debug_assert!(!self.get_finished());

        #[cfg(debug_assertions)]
        {
            let state = self.state.read();
            debug_assert!(state.deps.is_empty());
        }

        self.atomic_state.runnable_since.store(chrono::Utc::now());
        self.runnable.store(true, Ordering::SeqCst);
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

    pub times_build: i32,
    pub is_non_deterministic: bool,

    pub start_time: Option<chrono::DateTime<chrono::Utc>>,
    pub stop_time: Option<chrono::DateTime<chrono::Utc>>,

    pub overhead: i32,
    pub log_file: String,
}

impl RemoteBuild {
    pub fn new() -> Self {
        Self {
            step_status: BuildStatus::Aborted,
            can_retry: false,
            is_cached: false,
            can_cache: false,
            error_msg: None,
            times_build: 0,
            is_non_deterministic: false,
            start_time: None,
            stop_time: None,
            overhead: 0,
            log_file: String::new(),
        }
    }

    pub fn get_total_step_time_ms(&self) -> u64 {
        if let (Some(start_time), Some(stop_time)) = (self.start_time, self.stop_time) {
            (stop_time - start_time).num_milliseconds().unsigned_abs()
        } else {
            0
        }
    }

    pub fn update_with_result_state(&mut self, state: &BuildResultState) {
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

pub struct BuildOutput {
    pub failed: bool,
    pub import_elapsed: std::time::Duration,
    pub build_elapsed: std::time::Duration,

    pub release_name: Option<String>,

    pub closure_size: u64,
    pub size: u64,

    pub products: Vec<BuildProduct>,
    pub outputs: AHashMap<String, nix_utils::StorePath>,
    pub metrics: AHashMap<String, BuildMetric>,
}

impl TryFrom<db::models::BuildOutput> for BuildOutput {
    type Error = anyhow::Error;

    fn try_from(v: db::models::BuildOutput) -> anyhow::Result<Self> {
        let build_status = BuildStatus::from_i32(
            v.buildstatus
                .ok_or(anyhow::anyhow!("buildstatus missing"))?,
        )
        .ok_or(anyhow::anyhow!("buildstatus did not map"))?;
        Ok(Self {
            failed: build_status != BuildStatus::Success,
            import_elapsed: std::time::Duration::from_millis(0),
            build_elapsed: std::time::Duration::from_millis(0),
            release_name: v.releasename,
            #[allow(clippy::cast_sign_loss)]
            closure_size: v.closuresize.unwrap_or_default() as u64,
            #[allow(clippy::cast_sign_loss)]
            size: v.size.unwrap_or_default() as u64,
            products: vec![],
            outputs: AHashMap::new(),
            metrics: AHashMap::new(),
        })
    }
}

impl From<crate::server::grpc::runner_v1::BuildResultInfo> for BuildOutput {
    fn from(v: crate::server::grpc::runner_v1::BuildResultInfo) -> Self {
        let mut outputs = AHashMap::new();
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
            import_elapsed: std::time::Duration::from_millis(v.import_time_ms),
            build_elapsed: std::time::Duration::from_millis(v.build_time_ms),
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
        let pathinfos = store.query_path_infos(&flat_outputs);
        let nix_support = shared::parse_nix_support_from_outputs(&outputs).await?;

        let mut outputs_map = AHashMap::new();
        let mut closure_size = 0;
        let mut nar_size = 0;

        for o in outputs {
            if let Some(path) = o.path {
                if let Some(info) = pathinfos.get(&path) {
                    closure_size += store.compute_closure_size(&path);
                    nar_size += info.nar_size;
                    outputs_map.insert(o.name, path);
                }
            }
        }

        Ok(Self {
            failed: nix_support.failed,
            import_elapsed: std::time::Duration::from_millis(0),
            build_elapsed: std::time::Duration::from_millis(0),
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
    b: &'a Arc<crate::state::Build>,
    res: &'a crate::state::BuildOutput,
) -> db::models::MarkBuildSuccessData<'a> {
    db::models::MarkBuildSuccessData {
        id: b.id,
        name: &b.name,
        project_name: &b.jobset.project_name,
        jobset_name: &b.jobset.name,
        finished_in_db: b.get_finished_in_db(),
        timestamp: b.timestamp,
        failed: res.failed,
        closure_size: res.closure_size,
        size: res.size,
        release_name: res.release_name.as_deref(),
        outputs: res
            .outputs
            .iter()
            .map(|(name, path)| (name.clone(), path.get_full_path()))
            .collect(),
        products: res
            .products
            .iter()
            .map(|v| db::models::BuildProduct {
                r#type: &v.r#type,
                subtype: &v.subtype,
                filesize: v.file_size.and_then(|v| i64::try_from(v).ok()),
                sha256hash: v.sha256hash.as_deref(),
                path: v.path.as_ref().map(nix_utils::StorePath::get_full_path),
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
