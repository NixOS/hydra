use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use db::models::BuildID;
use harmonia_store_derivation::derivation::{BasicDerivation, Derivation};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_path::{StoreDir, StorePath};

use super::Step;
use super::drv::flatten_chain;
use crate::config::StepSortFn;

/// Resolve an input-addressed derivation output from the `.drv` file on
/// disk. The build-history lookup in the database can miss outputs that
/// never got a successful build step row, e.g. paths that were already
/// valid when the step was created or whose step was aborted by a
/// restart after the build finished. For input-addressed derivations the
/// output path is fixed by the derivation itself, so the file is
/// authoritative.
fn resolve_from_drv_file(
    store_dir: &StoreDir,
    drv_path: &StorePath,
    output_name: &OutputName,
) -> Option<StorePath> {
    let path = std::path::PathBuf::from(store_dir.display(drv_path).to_string());
    let content = fs_err::read(path).ok()?;
    let name = drv_path.name().strip_suffix(".drv")?.parse().ok()?;
    let drv = harmonia_store_aterm::parse_derivation_aterm(store_dir, &content, name).ok()?;
    let output = drv.outputs.get(output_name)?;
    output
        .path(store_dir, &drv.name, output_name)
        .ok()
        .flatten()
}

#[derive(Debug)]
pub struct StepInfo {
    pub step: Arc<Step>,
    already_scheduled: AtomicBool,
    cancelled: AtomicBool,
    pub runnable_since: jiff::Timestamp,
    lowest_share_used: atomic_float::AtomicF64,
}

impl StepInfo {
    pub fn new(step: Arc<Step>) -> Self {
        Self {
            already_scheduled: false.into(),
            cancelled: false.into(),
            runnable_since: step.get_runnable_since(),
            lowest_share_used: step.get_lowest_share_used().into(),
            step,
        }
    }

    /// Resolve a derivation's inputs into concrete store paths, returning a
    /// [`BasicDerivation`](BasicDerivation).
    ///
    /// Returns [`None`] if the derivation is input-addressed (shouldn't be resolved),
    /// or if resolution fails because required outputs haven't been built yet.
    ///
    /// If the derivation has no [`Built`](SingleDerivedPath::Built) inputs, it is
    /// already resolved; the inputs are simply flattened to a [`StorePathSet`].
    ///
    /// We only need a store dir, not a store, because all the info we need comes from the Hydra
    /// database.
    pub(super) async fn try_resolve_force(
        store_dir: &StoreDir,
        db: &db::Database,
        drv: &Derivation,
    ) -> Option<BasicDerivation> {
        // If there are no Built inputs, the derivation is already resolved.
        let has_built_inputs = drv
            .inputs
            .iter()
            .any(|i| matches!(i, SingleDerivedPath::Built { .. }));
        if !has_built_inputs {
            return Some(drv.clone().map_inputs(|inputs| {
                inputs
                    .into_iter()
                    .map(|sdp| match sdp {
                        SingleDerivedPath::Opaque(p) => p,
                        SingleDerivedPath::Built { .. } => unreachable!(),
                    })
                    .collect()
            }));
        }

        let mut conn = db.get().await.ok()?;

        drv.try_resolve_force(store_dir, &mut |inputs| {
            tokio::task::block_in_place(|| {
                // Flatten each SingleDerivedPath chain into (root, [outputs...])
                // and resolve everything in a single recursive SQL query.
                let chains: Vec<_> = inputs
                    .iter()
                    .map(|(drv_path, output_name)| flatten_chain(drv_path, output_name))
                    .collect();

                // SQL needs forward order; OutputNameChain stores reversed.
                let chain_refs: Vec<_> = chains
                    .iter()
                    .map(|(root, chain)| (root, chain.0.iter().rev().collect::<Vec<_>>()))
                    .collect();

                let sql_input: Vec<_> = chain_refs
                    .iter()
                    .map(|(root, outputs)| (*root, outputs.as_slice()))
                    .collect();

                let rt = tokio::runtime::Handle::current();
                let results = rt
                    .block_on(conn.resolve_drv_output_chains(store_dir, &sql_input))
                    .unwrap_or_else(|e| {
                        tracing::warn!("resolve_drv_output_chains failed: {e}");
                        vec![None; inputs.len()]
                    });

                // The build-history lookup can miss outputs that never got
                // a successful build step row. For chains the SQL couldn't
                // resolve, retry link by link, falling back to reading the
                // `.drv` file, which is authoritative for input-addressed
                // derivations. The per-link DB lookup matters too: a chain
                // can mix links known only to the DB with links whose drv
                // only exists on disk, and the recursive SQL stops at the
                // first miss.
                results
                    .into_iter()
                    .zip(&chain_refs)
                    .map(|(result, (root, outputs))| {
                        result.or_else(|| {
                            let mut current = (*root).clone();
                            for output_name in outputs {
                                current = rt
                                    .block_on(conn.resolve_drv_output(
                                        store_dir,
                                        &current,
                                        output_name,
                                    ))
                                    .unwrap_or_else(|e| {
                                        tracing::warn!("resolve_drv_output failed: {e}");
                                        None
                                    })
                                    .or_else(|| {
                                        resolve_from_drv_file(store_dir, &current, output_name)
                                    })?;
                            }
                            Some(current)
                        })
                    })
                    .collect()
            })
        })
    }

    pub fn update_internal_stats(&self) {
        self.lowest_share_used
            .store(self.step.get_lowest_share_used(), Ordering::Relaxed);
    }

    pub fn get_lowest_share_used(&self) -> f64 {
        self.lowest_share_used.load(Ordering::Relaxed)
    }

    pub fn get_highest_global_priority(&self) -> i32 {
        self.step
            .atomic_state
            .highest_global_priority
            .load(Ordering::Relaxed)
    }

    pub fn get_highest_local_priority(&self) -> i32 {
        self.step
            .atomic_state
            .highest_local_priority
            .load(Ordering::Relaxed)
    }

    pub fn get_lowest_build_id(&self) -> BuildID {
        self.step
            .atomic_state
            .lowest_build_id
            .load(Ordering::Relaxed)
    }

    pub fn get_already_scheduled(&self) -> bool {
        self.already_scheduled.load(Ordering::SeqCst)
    }

    pub fn set_already_scheduled(&self, v: bool) {
        self.already_scheduled.store(v, Ordering::SeqCst);
    }

    pub fn set_cancelled(&self, v: bool) {
        self.cancelled.store(v, Ordering::SeqCst);
    }

    pub fn get_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Snapshot the fields that `sort_fn` orders the queue by.
    pub(super) fn sort_key(&self, sort_fn: StepSortFn) -> SortKey {
        SortKey {
            global_priority: self.get_highest_global_priority(),
            share_used: self.get_lowest_share_used(),
            sort_fn_weight: match sort_fn {
                StepSortFn::Legacy => 0,
                StepSortFn::WithRdeps => self.step.get_rdeps_size(),
                StepSortFn::WithCriticalPath => self.step.get_cp_length(),
            },
            local_priority: self.get_highest_local_priority(),
            build_id: self.get_lowest_build_id(),
        }
    }
}

/// A step's position in the queue, read once per sort. The fields come from
/// live atomics. If the sort compared the atomics directly, they could change
/// mid-sort and break the total order that `sort_by` requires.
#[derive(Debug)]
pub(super) struct SortKey {
    global_priority: i32,
    share_used: f64,
    /// rdeps count or critical path length, depending on the sort function.
    /// Always 0 for Legacy.
    sort_fn_weight: u64,
    local_priority: i32,
    build_id: BuildID,
}

impl Ord for SortKey {
    /// Smaller keys sort first. Fields in order of precedence: higher global
    /// priority, lower share used, bigger `sort_fn_weight`, higher local priority,
    /// older build.
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other
            .global_priority
            .cmp(&self.global_priority)
            .then(self.share_used.total_cmp(&other.share_used))
            .then(other.sort_fn_weight.cmp(&self.sort_fn_weight))
            .then(other.local_priority.cmp(&self.local_priority))
            .then(self.build_id.cmp(&other.build_id))
    }
}

impl PartialOrd for SortKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for SortKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == std::cmp::Ordering::Equal
    }
}

impl Eq for SortKey {}

#[cfg(test)]
mod tests {
    use super::*;
    use db::models::BuildID;
    use std::cmp::Ordering::{Equal, Greater, Less};

    fn cmp(a: &StepInfo, b: &StepInfo, sort_fn: StepSortFn) -> std::cmp::Ordering {
        a.sort_key(sort_fn).cmp(&b.sort_key(sort_fn))
    }

    fn create_test_step(
        highest_global_priority: i32,
        highest_local_priority: i32,
        lowest_build_id: BuildID,
        lowest_share_used: f64,
        rdeps_len: u64,
    ) -> StepInfo {
        let step = Step::new(
            StorePath::from_base_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv").unwrap(),
            Arc::default(),
        );

        step.atomic_state
            .highest_global_priority
            .store(highest_global_priority, Ordering::Relaxed);
        step.atomic_state
            .highest_local_priority
            .store(highest_local_priority, Ordering::Relaxed);
        step.atomic_state
            .lowest_build_id
            .store(lowest_build_id, Ordering::Relaxed);
        step.atomic_state
            .rdeps_len
            .store(rdeps_len, Ordering::Relaxed);

        StepInfo {
            step,
            already_scheduled: false.into(),
            cancelled: false.into(),
            runnable_since: jiff::Timestamp::now(),
            lowest_share_used: lowest_share_used.into(),
        }
    }

    #[test]
    fn test_legacy_sort_key_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Equal);
    }

    #[test]
    fn test_rdeps_sort_key_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_rdeps_size() {
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 2, 1.0, 5);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Equal);
    }

    #[test]
    fn test_sort_fn_weight_only_for_rdeps() {
        // Same global priority, share used, local priority, and build ID
        // but a different rdeps_len. WithRdeps should order them, Legacy should not.
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 1, 1.0, 5);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Equal);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }
}
