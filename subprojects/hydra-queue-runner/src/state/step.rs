use std::collections::BTreeMap;
use std::hash::Hash;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Weak};

use hashbrown::{HashMap, HashSet};

use super::{Build, Jobset};
use db::models::BuildID;
use harmonia_store_derivation::derivation::Derivation;
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use super::drv::OutputNameChain;

#[derive(Debug, Clone)]
pub struct ReverseDep {
    /// The step that depends on us
    pub step: Weak<Step>,
    pub relation: OutputNameChain,
}

#[derive(Debug)]
pub struct StepAtomicState {
    /// Whether the step has finished initialisation.
    created: AtomicBool,
    /// Number of times we've tried this step.
    pub tries: AtomicU32,
    /// The highest global priority of any build depending on this step.
    pub highest_global_priority: AtomicI32,
    /// The highest local priority of any build depending on this step.
    pub highest_local_priority: AtomicI32,

    /// The lowest ID of any build depending on this step.
    pub lowest_build_id: super::build::AtomicBuildID,

    /// Point in time after which the step can be retried.
    pub after: super::AtomicDateTime,
    /// The time at which this step became runnable.
    pub runnable_since: super::AtomicDateTime,
    /// The time that we last saw a machine that supports this step
    pub last_supported: super::AtomicDateTime,

    pub deps_len: AtomicU64,
    pub rdeps_len: AtomicU64,
    /// Length of the longest chain of unfinished steps depending on this
    /// step (in steps, including itself). Recomputed before dispatch.
    pub cp_length: AtomicU64,
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
            cp_length: 0.into(),
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
pub(super) struct StepState {
    /// The resolved build steps on which this step depends
    deps: HashSet<Arc<Step>>,
    /// The build steps that depend on this step.
    /// An empty `relation` signifies a regular (non-dynamic) reverse dependency.
    rdeps: Vec<ReverseDep>,
    /// Builds that have this step as the top-level derivation.
    builds: Vec<Weak<Build>>,
    /// Jobsets to which this step belongs. Used for determining scheduling priority.
    jobsets: HashSet<Arc<Jobset>>,
}

impl Default for StepState {
    fn default() -> Self {
        Self::new()
    }
}

impl StepState {
    pub(super) fn new() -> Self {
        Self {
            deps: HashSet::new(),
            rdeps: Vec::new(),
            builds: Vec::new(),
            jobsets: HashSet::new(),
        }
    }
}

/// Steps that became runnable since the dispatcher last drained them.
pub(super) type PendingRunnable = Arc<parking_lot::Mutex<Vec<Weak<Step>>>>;

/// The subset of a step's derivation needed for scheduling. Keeping only
/// this instead of the full parsed `Derivation` bounds per-step memory; the
/// full derivation is re-read from the store when the step is realised.
#[derive(Debug)]
pub(crate) struct StepDrvInfo {
    system: String,
    output_paths: BTreeMap<OutputName, Option<StorePath>>,
    pub(crate) required_features: Vec<String>,
    has_ca_floating: bool,
}

/// Extract `requiredSystemFeatures`, handling `__structuredAttrs` derivations.
///
/// Such derivations carry the attribute only inside the `__json` blob (parsed
/// into `structured_attrs`) with no flat env var, so reading the env alone
/// mis-schedules them onto machines lacking the feature (e.g. `big-parallel`).
fn required_features(drv: &Derivation) -> Vec<String> {
    if let Some(structured) = &drv.structured_attrs {
        let Some(serde_json::Value::Array(features)) =
            structured.attrs.get("requiredSystemFeatures")
        else {
            return Vec::new();
        };
        return features
            .iter()
            .filter_map(|v| v.as_str().map(ToOwned::to_owned))
            .collect();
    }

    drv.env
        .get(b"requiredSystemFeatures".as_slice())
        .and_then(|v| std::str::from_utf8(v).ok())
        .map(|v| v.split_whitespace().map(ToOwned::to_owned).collect())
        .unwrap_or_default()
}

impl StepDrvInfo {
    /// # Panics
    ///
    /// Will panic if drv.platform is not a UTF-8 string
    #[must_use]
    pub(crate) fn new(drv: &Derivation, store_dir: &StoreDir) -> Self {
        #[allow(clippy::expect_used)]
        Self {
            system: std::str::from_utf8(&drv.platform)
                .expect("platform must be valid UTF-8")
                .to_owned(),
            output_paths: drv
                .outputs
                .iter()
                .map(|(name, output)| {
                    (
                        name.clone(),
                        output.path(store_dir, &drv.name, name).ok().flatten(),
                    )
                })
                .collect(),
            required_features: required_features(drv),
            has_ca_floating: drv.outputs.values().any(|o| {
                matches!(
                    o,
                    harmonia_store_derivation::derivation::DerivationOutput::CAFloating(_)
                )
            }),
        }
    }
}

#[derive(Debug)]
pub struct Step {
    drv_path: StorePath,
    drv_info: arc_swap::ArcSwapOption<StepDrvInfo>,
    me: Weak<Step>,
    pending_runnable: PendingRunnable,

    runnable: AtomicBool,
    /// The step is currently held in the dispatch queues.
    queued: AtomicBool,
    finished: AtomicBool,
    previous_failure: AtomicBool,
    /// An upload of this step's outputs to the remote binary cache has been
    /// scheduled. Guards against re-scheduling on every queue run while the
    /// upload is still in flight.
    upload_scheduled: AtomicBool,
    pub atomic_state: StepAtomicState,
    state: parking_lot::RwLock<StepState>,
}

impl PartialEq for Step {
    fn eq(&self, other: &Self) -> bool {
        self.drv_path == other.drv_path
    }
}

impl Eq for Step {}

impl Hash for Step {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        // ensure that drv_path is never mutable
        // as we set Step as ignore-interior-mutability
        Hash::hash(&self.drv_path, state);
    }
}

/// Hashes and compares an `Arc<Step>` by allocation address instead of the
/// expensive `StorePath` content hash. Holding the `Arc` pins the address so
/// it cannot be reused by a step allocated later.
#[derive(Clone)]
pub struct ByPtr(pub Arc<Step>);

impl std::fmt::Debug for ByPtr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("ByPtr").field(&Arc::as_ptr(&self.0)).finish()
    }
}

impl PartialEq for ByPtr {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl Eq for ByPtr {}

impl Hash for ByPtr {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        (Arc::as_ptr(&self.0) as usize).hash(state);
    }
}

impl Step {
    #[must_use]
    pub fn new(drv_path: StorePath, pending_runnable: PendingRunnable) -> Arc<Self> {
        Arc::new_cyclic(|me| Self {
            drv_path,
            drv_info: arc_swap::ArcSwapOption::from(None),
            me: me.clone(),
            pending_runnable,
            runnable: false.into(),
            queued: false.into(),
            finished: false.into(),
            previous_failure: false.into(),
            upload_scheduled: false.into(),
            atomic_state: StepAtomicState::new(
                jiff::Timestamp::UNIX_EPOCH,
                jiff::Timestamp::UNIX_EPOCH,
            ),
            state: parking_lot::RwLock::new(StepState::new()),
        })
    }

    #[inline]
    pub const fn get_drv_path(&self) -> &StorePath {
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

    /// Marks the step as queued; returns true if it wasn't already.
    pub fn try_mark_queued(&self) -> bool {
        !self.queued.swap(true, Ordering::SeqCst)
    }

    /// Called when the step is dropped from the dispatch queues.
    pub fn clear_queued(&self) {
        self.queued.store(false, Ordering::SeqCst);
    }

    /// Returns true only the first time, so a step's upload is scheduled
    /// once even when the step is revisited by later queue runs.
    pub fn try_mark_upload_scheduled(&self) -> bool {
        !self.upload_scheduled.swap(true, Ordering::SeqCst)
    }

    /// Whether the step waits for its outputs to reach the remote binary
    /// cache before it may count as finished.
    pub fn has_pending_upload(&self) -> bool {
        self.upload_scheduled.load(Ordering::SeqCst) && !self.get_finished()
    }

    /// # Panics
    ///
    /// Will panic if drv.platform is not a UTF-8 string
    pub fn set_drv(&self, drv: &Derivation, store_dir: &StoreDir) {
        self.drv_info
            .store(Some(Arc::new(StepDrvInfo::new(drv, store_dir))));
    }

    pub fn has_ca_floating_outputs(&self) -> bool {
        self.drv_info.load_full().is_some_and(|i| i.has_ca_floating)
    }

    pub fn get_system(&self) -> Option<String> {
        self.drv_info.load_full().map(|i| i.system.clone())
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

    pub fn get_output_paths(&self) -> Option<BTreeMap<OutputName, Option<StorePath>>> {
        self.drv_info.load_full().map(|i| i.output_paths.clone())
    }

    // TODO: properly parse derivation options instead of reading env vars directly
    pub(crate) fn drv_info(&self) -> Option<Arc<StepDrvInfo>> {
        self.drv_info.load_full()
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
            let Some(rdep) = rdep.step.upgrade() else {
                continue;
            };
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
            let Some(rdep) = rdep.step.upgrade() else {
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
            tracing::debug!("step '{}' is now runnable", self.get_drv_path());

            self.runnable.store(true, Ordering::SeqCst);
            self.pending_runnable.lock().push(self.me.clone());
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

    /// Add `dep` to this step's forward deps unless it already finished.
    ///
    /// The finished flag is checked while holding this step's state lock:
    /// a finishing dep's `make_rdeps_runnable` takes the same lock to clear
    /// the dep from `deps`, so we either observe the dep as finished here
    /// and skip it, or its cleanup runs after our insertion and removes it
    /// again. Checking before taking the lock left a window in which the
    /// dep finished in between and this step waited on it forever.
    ///
    /// Returns whether the dep was added.
    pub fn add_dep_if_unfinished(&self, dep: Arc<Self>) -> bool {
        let mut state = self.state.write();
        if dep.get_finished() {
            return false;
        }
        state.deps.insert(dep);
        self.atomic_state
            .deps_len
            .store(state.deps.len() as u64, Ordering::Relaxed);
        true
    }

    pub fn add_dep(&self, dep: Arc<Self>) {
        let mut state = self.state.write();
        state.deps.insert(dep);
        self.atomic_state
            .deps_len
            .store(state.deps.len() as u64, Ordering::Relaxed);
    }

    pub fn remove_dep(&self, dep: &Arc<Self>) {
        let mut state = self.state.write();
        state.deps.remove(dep);
        self.atomic_state
            .deps_len
            .store(state.deps.len() as u64, Ordering::Relaxed);
    }

    pub fn make_rdep(self: &Arc<Self>, dep: &Arc<Self>) {
        dep.add_dep(self.clone());
        let mut state = self.state.write();
        state.rdeps.push(ReverseDep {
            step: Arc::downgrade(dep),
            relation: OutputNameChain::default(),
        });
        self.atomic_state
            .rdeps_len
            .store(state.rdeps.len() as u64, Ordering::Relaxed);
    }

    pub fn clone_rdeps(&self) -> Vec<ReverseDep> {
        let state = self.state.read();
        state.rdeps.clone()
    }

    /// Pop one level of dynamic indirection from each dynamic rdep,
    /// returning `(dependent_step, popped_output_name, remaining_relation)` triples.
    ///
    /// The rdep entries remain in the list (with shortened relations) so that
    /// `make_rdeps_runnable` can still clean up forward deps.
    ///
    /// We collect into a `Vec` rather than returning an iterator because the
    /// write lock on the step's state must be released before the caller can
    /// do async work (e.g. `create_step`) with the results.
    pub fn pop_dynamic_rdeps(&self) -> Vec<(Weak<Step>, OutputName, OutputNameChain)> {
        let mut state = self.state.write();
        state
            .rdeps
            .iter_mut()
            .filter_map(|rdep| {
                let output_name = rdep.relation.pop()?;
                Some((rdep.step.clone(), output_name, rdep.relation.clone()))
            })
            .collect()
    }

    pub fn add_referring_data(
        &self,
        referring_build: Option<&Arc<Build>>,
        referring_step: Option<(&Arc<Self>, OutputNameChain)>,
    ) {
        if referring_build.is_none() && referring_step.is_none() {
            return;
        }

        let mut state = self.state.write();
        if let Some(referring_build) = referring_build {
            state.builds.push(Arc::downgrade(referring_build));
        }
        if let Some((referring_step, relation)) = referring_step {
            state.rdeps.push(ReverseDep {
                step: Arc::downgrade(referring_step),
                relation,
            });
            self.atomic_state
                .rdeps_len
                .store(state.rdeps.len() as u64, Ordering::Relaxed);
        }
    }

    pub fn get_direct_builds(&self) -> Vec<Arc<Build>> {
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

    /// Returns dependencies not yet visited during a propagation walk, keyed
    /// by [`ByPtr`] to avoid hashing the full `StorePath` on every edge.
    pub fn get_all_deps_not_queued(&self, visited: &HashSet<ByPtr>) -> Vec<Arc<Self>> {
        let state = self.state.read();
        state
            .deps
            .iter()
            .filter(|dep| !visited.contains(&ByPtr(Arc::clone(dep))))
            .map(Clone::clone)
            .collect()
    }
}

#[derive(Debug, Clone)]
pub struct Steps {
    inner: Arc<parking_lot::RwLock<HashMap<StorePath, Weak<Step>>>>,
    pending_runnable: PendingRunnable,
    /// Last critical-path recomputation (unix seconds); the DFS over the
    /// whole step graph is too expensive to run on every dispatch round.
    cp_computed_at: Arc<AtomicU64>,
    /// Last full runnable scan (unix seconds).
    full_scan_at: Arc<AtomicU64>,
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
            pending_runnable: Arc::default(),
            cp_computed_at: Arc::new(0.into()),
            full_scan_at: Arc::new(0.into()),
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
            .filter_map(Weak::upgrade)
            .map(Into::into)
            .collect()
    }

    #[must_use]
    pub fn clone_runnable_as_io(&self) -> Vec<crate::io::Step> {
        let steps = self.inner.read();
        steps
            .values()
            .filter_map(Weak::upgrade)
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

    /// Drain steps that became runnable since the last call.
    #[must_use]
    pub fn drain_pending_runnable(&self) -> Vec<Arc<Step>> {
        let pending: Vec<_> = std::mem::take(&mut *self.pending_runnable.lock());
        pending.iter().filter_map(Weak::upgrade).collect()
    }

    /// Full scan at most every `interval_s` seconds; safety net for steps
    /// that left the queues without finishing.
    #[must_use]
    pub fn clone_runnable_throttled(&self, interval_s: u64) -> Vec<Arc<Step>> {
        #[allow(clippy::cast_sign_loss)]
        let now = jiff::Timestamp::now().as_second() as u64;
        let last = self.full_scan_at.load(Ordering::Relaxed);
        if now.saturating_sub(last) < interval_s {
            return Vec::new();
        }
        self.full_scan_at.store(now, Ordering::Relaxed);
        self.clone_runnable()
    }

    /// Recompute critical paths at most every `interval_s` seconds.
    pub fn compute_critical_paths_throttled(&self, interval_s: u64) {
        let now = u64::try_from(jiff::Timestamp::now().as_second()).unwrap_or(0);
        let last = self.cp_computed_at.load(Ordering::Relaxed);
        if now.saturating_sub(last) < interval_s {
            return;
        }
        if self
            .cp_computed_at
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            self.compute_critical_paths();
        }
    }

    /// Recompute `cp_length` for all live steps: the number of steps on the
    /// longest chain of unfinished reverse dependencies, including the step
    /// itself. Iterative DFS; chains can be thousands of steps deep.
    pub fn compute_critical_paths(&self) {
        let steps: Vec<Arc<Step>> = {
            let inner = self.inner.read();
            inner.values().filter_map(Weak::upgrade).collect()
        };
        let mut done: HashMap<StorePath, u64> = HashMap::with_capacity(steps.len());
        for root in &steps {
            if done.contains_key(root.get_drv_path()) {
                continue;
            }
            let mut stack: Vec<(Arc<Step>, bool)> = vec![(root.clone(), false)];
            while let Some((step, expanded)) = stack.pop() {
                if done.contains_key(step.get_drv_path()) {
                    continue;
                }
                let rdeps: Vec<Arc<Step>> = {
                    let state = step.state.read();
                    state
                        .rdeps
                        .iter()
                        .filter_map(|r| r.step.upgrade())
                        .collect()
                };
                if expanded {
                    let longest_rdep = rdeps
                        .iter()
                        .filter_map(|r| done.get(r.get_drv_path()))
                        .max()
                        .copied()
                        .unwrap_or(0);
                    let cp = if step.get_finished() {
                        0
                    } else {
                        longest_rdep + 1
                    };
                    step.atomic_state.cp_length.store(cp, Ordering::Relaxed);
                    done.insert(step.get_drv_path().clone(), cp);
                } else {
                    stack.push((step.clone(), true));
                    for r in rdeps {
                        if !done.contains_key(r.get_drv_path()) {
                            stack.push((r, false));
                        }
                    }
                }
            }
        }
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
        drv_path: &StorePath,
        referring_build: Option<&Arc<Build>>,
        referring_step: Option<(&Arc<Step>, OutputNameChain)>,
    ) -> (Arc<Step>, bool) {
        let mut is_new = false;
        let mut steps = self.inner.write();
        let step = if let Some(step) = steps.get(drv_path) {
            step.upgrade().unwrap_or_else(|| {
                steps.remove(drv_path);
                is_new = true;
                Step::new(drv_path.to_owned(), self.pending_runnable.clone())
            })
        } else {
            is_new = true;
            Step::new(drv_path.to_owned(), self.pending_runnable.clone())
        };

        step.add_referring_data(referring_build, referring_step);
        steps.insert(drv_path.to_owned(), Arc::downgrade(&step));
        (step, is_new)
    }

    #[must_use]
    pub fn get(&self, drv_path: &StorePath) -> Option<Arc<Step>> {
        self.inner.read().get(drv_path).and_then(Weak::upgrade)
    }

    pub fn remove(&self, drv_path: &StorePath) {
        let mut steps = self.inner.write();
        steps.remove(drv_path);
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn drv(name: &str) -> StorePath {
        StorePath::from_base_path(&format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-{name}.drv")).unwrap()
    }

    fn empty_derivation() -> Derivation {
        Derivation {
            name: "test".parse().unwrap(),
            outputs: BTreeMap::new(),
            inputs: std::collections::BTreeSet::new(),
            platform: bytes::Bytes::from_static(b"x86_64-linux"),
            builder: bytes::Bytes::from_static(b"/bin/sh"),
            args: Vec::new(),
            env: BTreeMap::new(),
            structured_attrs: None,
        }
    }

    #[test]
    fn required_features_from_flat_env() {
        let mut drv = empty_derivation();
        drv.env.insert(
            bytes::Bytes::from_static(b"requiredSystemFeatures"),
            bytes::Bytes::from_static(b"big-parallel kvm"),
        );
        assert_eq!(required_features(&drv), vec!["big-parallel", "kvm"]);
    }

    #[test]
    fn required_features_from_structured_attrs() {
        // __structuredAttrs derivations carry requiredSystemFeatures only in
        // the JSON blob, with no flat env var. Reading the flat var alone
        // would mis-schedule them (e.g. kernel builds losing big-parallel).
        let mut drv = empty_derivation();
        let attrs = serde_json::json!({
            "requiredSystemFeatures": ["big-parallel"],
        });
        drv.structured_attrs = Some(harmonia_store_derivation::derivation::StructuredAttrs {
            attrs: attrs.as_object().unwrap().clone(),
        });
        assert_eq!(required_features(&drv), vec!["big-parallel"]);
    }

    #[test]
    fn pending_runnable_drained_once() {
        let steps = Steps::new();
        let (step, _) = steps.create(&drv("a"), None, None);
        step.atomic_state.set_created(true);
        step.make_runnable();
        step.make_runnable();

        let drained = steps.drain_pending_runnable();
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].get_drv_path(), step.get_drv_path());
        assert!(steps.drain_pending_runnable().is_empty());
    }

    #[test]
    fn steps_create_and_remove() {
        let steps = Steps::new();
        let (step, is_new) = steps.create(&drv("test"), None, None);
        assert!(is_new);
        assert_eq!(steps.len(), 1);

        steps.remove(step.get_drv_path());
        assert_eq!(steps.len(), 0);
    }

    #[test]
    fn critical_path_lengths() {
        // c depends on b depends on a; d also depends on a. a's cp comes
        // from the longer chain through b.
        let steps = Steps::new();
        let (c, _) = steps.create(&drv("c"), None, None);
        let (b, _) = steps.create(&drv("b"), None, Some((&c, OutputNameChain::default())));
        let (a, _) = steps.create(&drv("a"), None, Some((&b, OutputNameChain::default())));
        let (d, _) = steps.create(&drv("d"), None, None);
        let (_, is_new) = steps.create(&drv("a"), None, Some((&d, OutputNameChain::default())));
        assert!(!is_new);

        steps.compute_critical_paths();
        let cp = |s: &Arc<Step>| s.atomic_state.cp_length.load(Ordering::Relaxed);
        assert_eq!(cp(&a), 3); // a -> b -> c
        assert_eq!(cp(&b), 2);
        assert_eq!(cp(&c), 1);
        assert_eq!(cp(&d), 1);

        // finished steps drop out of the chain
        c.set_finished(true);
        steps.compute_critical_paths();
        assert_eq!(cp(&a), 2);
    }

    #[test]
    fn steps_weak_ref_dies_without_strong_ref() {
        let steps = Steps::new();
        let (step, _) = steps.create(&drv("ephemeral"), None, None);
        assert_eq!(steps.len(), 1);

        drop(step);
        assert_eq!(steps.len(), 0);
    }

    #[test]
    fn byptr_uses_identity_not_content() {
        // Distinct allocations with identical drv_path: equal under Step's
        // content Hash/Eq, but distinct under ByPtr.
        let a = Step::new(drv("same"), PendingRunnable::default());
        let b = Step::new(drv("same"), PendingRunnable::default());
        assert_eq!(a, b, "content equality precondition");
        assert!(!Arc::ptr_eq(&a, &b));

        let mut set = HashSet::new();
        assert!(set.insert(ByPtr(a.clone())));
        assert!(!set.insert(ByPtr(a.clone())));
        assert!(set.contains(&ByPtr(a.clone())));
        assert!(set.insert(ByPtr(b.clone())));
        assert!(!set.contains(&ByPtr(Step::new(drv("same"), PendingRunnable::default()))));
        assert_eq!(set.len(), 2);
    }
}
