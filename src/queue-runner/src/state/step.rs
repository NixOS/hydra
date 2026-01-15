use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Weak};

use hashbrown::{HashMap, HashSet};

use super::{Build, Jobset};
use db::models::BuildID;

#[derive(Debug)]
pub struct StepAtomicState {
    created: AtomicBool,  // Whether the step has finished initialisation.
    pub tries: AtomicU32, // Number of times we've tried this step.
    pub highest_global_priority: AtomicI32, // The highest global priority of any build depending on this step.
    pub highest_local_priority: AtomicI32, // The highest local priority of any build depending on this step.

    pub lowest_build_id: super::build::AtomicBuildID, // The lowest ID of any build depending on this step.

    pub after: super::AtomicDateTime, // Point in time after which the step can be retried.
    pub runnable_since: super::AtomicDateTime, // The time at which this step became runnable.
    pub last_supported: super::AtomicDateTime, // The time that we last saw a machine that supports this step

    pub deps_len: AtomicU64,
    pub rdeps_len: AtomicU64,
}

impl StepAtomicState {
    pub fn new(after: jiff::Timestamp, runnable_since: jiff::Timestamp) -> Self {
        Self {
            created: false.into(),
            tries: 0.into(),
            highest_global_priority: 0.into(),
            highest_local_priority: 0.into(),
            lowest_build_id: BuildID::MAX.into(),
            after: super::AtomicDateTime::new(after),
            runnable_since: super::AtomicDateTime::new(runnable_since),
            // Set the default of last_supported to runnable_since.
            // This fixes an issue that a step is marked as unsupported immediatly, if we currently
            // dont have a machine that supports system/all features.
            // So we still follow max_unsupported_time
            last_supported: super::AtomicDateTime::new(runnable_since),
            deps_len: 0.into(),
            rdeps_len: 0.into(),
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
    deps: HashSet<Arc<Step>>,      // The build steps on which this step depends.
    rdeps: Vec<Weak<Step>>,        // The build steps that depend on this step.
    builds: Vec<Weak<Build>>,      // Builds that have this step as the top-level derivation.
    jobsets: HashSet<Arc<Jobset>>, // Jobsets to which this step belongs. Used for determining scheduling priority.
}

impl Default for StepState {
    fn default() -> Self {
        Self::new()
    }
}

impl StepState {
    pub fn new() -> Self {
        Self {
            deps: HashSet::new(),
            rdeps: Vec::new(),
            builds: Vec::new(),
            jobsets: HashSet::new(),
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
    state: parking_lot::RwLock<StepState>,
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
    #[must_use]
    pub fn new(drv_path: nix_utils::StorePath) -> Arc<Self> {
        Arc::new(Self {
            drv_path,
            drv: arc_swap::ArcSwapOption::from(None),
            runnable: false.into(),
            finished: false.into(),
            previous_failure: false.into(),
            atomic_state: StepAtomicState::new(
                jiff::Timestamp::UNIX_EPOCH,
                jiff::Timestamp::UNIX_EPOCH,
            ),
            state: parking_lot::RwLock::new(StepState::new()),
        })
    }

    #[inline]
    pub const fn get_drv_path(&self) -> &nix_utils::StorePath {
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
        drv.as_ref().map(|drv| drv.input_drvs.to_vec())
    }

    pub fn get_after(&self) -> jiff::Timestamp {
        self.atomic_state.after.load()
    }

    pub fn set_after(&self, v: jiff::Timestamp) {
        self.atomic_state.after.store(v);
    }

    pub fn get_runnable_since(&self) -> jiff::Timestamp {
        self.atomic_state.runnable_since.load()
    }

    pub fn get_last_supported(&self) -> jiff::Timestamp {
        self.atomic_state.last_supported.load()
    }

    pub fn set_last_supported_now(&self) {
        self.atomic_state
            .last_supported
            .store(jiff::Timestamp::now());
    }

    pub fn get_outputs(&self) -> Option<Vec<nix_utils::DerivationOutput>> {
        let drv = self.drv.load_full();
        drv.as_ref().map(|drv| drv.outputs.to_vec())
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
        builds: &mut HashSet<Arc<Build>>,
        steps: &mut HashSet<Arc<Self>>,
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

    pub fn get_deps_size(&self) -> u64 {
        self.atomic_state.deps_len.load(Ordering::Relaxed)
    }

    pub fn make_rdeps_runnable(&self) {
        if !self.get_finished() {
            return;
        }

        let mut state = self.state.write();
        state.rdeps.retain(|rdep| {
            let Some(rdep) = rdep.upgrade() else {
                return false;
            };

            let mut runnable = false;
            {
                let mut rdep_state = rdep.state.write();
                rdep_state
                    .deps
                    .retain(|s| s.get_drv_path() != self.get_drv_path());
                rdep.atomic_state
                    .deps_len
                    .store(rdep_state.deps.len() as u64, Ordering::Relaxed);
                if rdep_state.deps.is_empty() && rdep.atomic_state.get_created() {
                    runnable = true;
                }
            }

            if runnable {
                rdep.make_runnable();
            }
            true
        });
        self.atomic_state
            .rdeps_len
            .store(state.rdeps.len() as u64, Ordering::Relaxed);
    }

    #[tracing::instrument(skip(self))]
    pub fn make_runnable(&self) {
        debug_assert!(self.atomic_state.created.load(Ordering::SeqCst));
        debug_assert!(!self.get_finished());

        #[cfg(debug_assertions)]
        {
            let state = self.state.read();
            debug_assert!(state.deps.is_empty());
        }

        // only ever mark as runnable once
        if !self.runnable.load(Ordering::SeqCst) {
            tracing::info!("step '{}' is now runnable", self.get_drv_path());

            self.runnable.store(true, Ordering::SeqCst);
            let now = jiff::Timestamp::now();
            self.atomic_state.runnable_since.store(now);
            // we also say now, is the last time that we supported this step.
            // This ensure that we actually wait for max_unsupported_time until we mark it as
            // unsupported. See also [`StepAtomicState::new`]
            self.atomic_state.last_supported.store(now);
        }
    }

    pub fn get_lowest_share_used(&self) -> f64 {
        let state = self.state.read();

        state
            .jobsets
            .iter()
            .map(|v| v.share_used())
            .min_by(f64::total_cmp)
            .unwrap_or(1e9)
    }

    pub fn add_jobset(&self, jobset: Arc<Jobset>) {
        let mut state = self.state.write();
        state.jobsets.insert(jobset);
    }

    pub fn add_dep(&self, dep: Arc<Self>) {
        let mut state = self.state.write();
        state.deps.insert(dep);
        self.atomic_state
            .deps_len
            .store(state.deps.len() as u64, Ordering::Relaxed);
    }

    pub fn add_referring_data(
        &self,
        referring_build: Option<&Arc<crate::state::Build>>,
        referring_step: Option<&Arc<Self>>,
    ) {
        if referring_build.is_none() && referring_step.is_none() {
            return;
        }

        let mut state = self.state.write();
        if let Some(referring_build) = referring_build {
            state.builds.push(Arc::downgrade(referring_build));
        }
        if let Some(referring_step) = referring_step {
            state.rdeps.push(Arc::downgrade(referring_step));
            self.atomic_state
                .rdeps_len
                .store(state.rdeps.len() as u64, Ordering::Relaxed);
        }
    }

    pub fn get_direct_builds(&self) -> Vec<Arc<crate::state::Build>> {
        let mut direct = Vec::new();
        let state = self.state.read();
        for b in &state.builds {
            let Some(b) = b.upgrade() else {
                continue;
            };
            if !b.get_finished_in_db() {
                direct.push(b);
            }
        }

        direct
    }

    pub fn get_all_deps_not_queued(&self, queued: &HashSet<Arc<Self>>) -> Vec<Arc<Self>> {
        let state = self.state.read();
        state
            .deps
            .iter()
            .filter(|dep| !queued.contains(*dep))
            .map(Clone::clone)
            .collect()
    }
}

#[derive(Clone)]
pub struct Steps {
    inner: Arc<parking_lot::RwLock<HashMap<nix_utils::StorePath, Weak<Step>>>>,
}

impl Default for Steps {
    fn default() -> Self {
        Self::new()
    }
}

impl Steps {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(parking_lot::RwLock::new(HashMap::with_capacity(10000))),
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        let mut steps = self.inner.write();
        steps.retain(|_, s| s.upgrade().is_some());
        steps.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        let mut steps = self.inner.write();
        steps.retain(|_, s| s.upgrade().is_some());
        steps.is_empty()
    }

    #[must_use]
    pub fn len_runnable(&self) -> usize {
        let mut steps = self.inner.write();
        steps.retain(|_, s| s.upgrade().is_some());
        steps
            .iter()
            .filter_map(|(_, s)| s.upgrade().map(|v| v.get_runnable()))
            .filter(|v| *v)
            .count()
    }

    #[must_use]
    pub fn clone_as_io(&self) -> Vec<crate::io::Step> {
        let steps = self.inner.read();
        steps
            .values()
            .filter_map(std::sync::Weak::upgrade)
            .map(Into::into)
            .collect()
    }

    #[must_use]
    pub fn clone_runnable_as_io(&self) -> Vec<crate::io::Step> {
        let steps = self.inner.read();
        steps
            .values()
            .filter_map(std::sync::Weak::upgrade)
            .filter(|v| v.get_runnable())
            .map(Into::into)
            .collect()
    }

    #[must_use]
    pub fn clone_runnable(&self) -> Vec<Arc<Step>> {
        let mut steps = self.inner.write();
        let mut new_runnable = Vec::with_capacity(steps.len());
        steps.retain(|_, r| {
            let Some(step) = r.upgrade() else {
                return false;
            };
            if step.get_runnable() {
                new_runnable.push(step);
            }
            true
        });
        new_runnable
    }

    pub fn make_rdeps_runnable(&self) {
        let steps = self.inner.read();
        for (_, s) in steps.iter() {
            let Some(s) = s.upgrade() else {
                continue;
            };
            if s.get_finished() && !s.get_previous_failure() {
                s.make_rdeps_runnable();
            }
            // TODO: if previous failure we should propably also remove from deps
        }
    }

    #[must_use]
    pub fn create(
        &self,
        drv_path: &nix_utils::StorePath,
        referring_build: Option<&Arc<Build>>,
        referring_step: Option<&Arc<Step>>,
    ) -> (Arc<Step>, bool) {
        let mut is_new = false;
        let mut steps = self.inner.write();
        let step = if let Some(step) = steps.get(drv_path) {
            step.upgrade().map_or_else(
                || {
                    steps.remove(drv_path);
                    is_new = true;
                    Step::new(drv_path.to_owned())
                },
                |step| step,
            )
        } else {
            is_new = true;
            Step::new(drv_path.to_owned())
        };

        step.add_referring_data(referring_build, referring_step);
        steps.insert(drv_path.to_owned(), Arc::downgrade(&step));
        (step, is_new)
    }

    pub fn remove(&self, drv_path: &nix_utils::StorePath) {
        let mut steps = self.inner.write();
        steps.remove(drv_path);
    }
}
