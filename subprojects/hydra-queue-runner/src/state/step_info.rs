use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use db::models::BuildID;
use harmonia_store_derivation::derivation::{BasicDerivation, Derivation};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_path::{StoreDir, StorePath};

use super::Step;
use super::drv::flatten_chain;

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
        resolved_drv_map: &hashbrown::HashMap<StorePath, StorePath>,
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

        // Memoize depth-1 lookups across all chains resolved in this call.
        let mut memo =
            std::collections::HashMap::<(StorePath, OutputName), Option<StorePath>>::new();

        drv.try_resolve_force(store_dir, &mut |inputs| {
            tokio::task::block_in_place(|| {
                let rt = tokio::runtime::Handle::current();

                let chains: Vec<_> = inputs
                    .iter()
                    .map(|(drv_path, output_name)| flatten_chain(drv_path, output_name))
                    .collect();

                // Resolve each chain one level at a time, translating
                // through the in-memory resolved-drv map between levels.
                chains
                    .iter()
                    .map(|(root, chain)| {
                        let mut current = root.clone();
                        // OutputNameChain is in stack order; iterate
                        // reversed for forward (root-to-leaf) order.
                        for output_name in chain.0.iter().rev() {
                            let translated = resolved_drv_map
                                .get(&current)
                                .cloned()
                                .unwrap_or_else(|| current.clone());
                            let key = (translated, output_name.clone());
                            let result = if let Some(cached) = memo.get(&key) {
                                cached.clone()
                            } else {
                                let r = rt
                                    .block_on(conn.resolve_drv_output(store_dir, &key.0, &key.1))
                                    .unwrap_or_else(|e| {
                                        tracing::warn!("resolve_drv_output failed: {e}");
                                        None
                                    })
                                    .or_else(|| resolve_from_drv_file(store_dir, &key.0, &key.1));
                                memo.insert(key, r.clone());
                                r
                            };
                            current = result?;
                        }
                        Some(current)
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

    pub(super) fn legacy_compare(&self, other: &Self) -> std::cmp::Ordering {
        #[allow(irrefutable_let_patterns)]
        (if let c1 = self
            .get_highest_global_priority()
            .cmp(&other.get_highest_global_priority())
            && c1 != std::cmp::Ordering::Equal
        {
            c1
        } else if let c2 = other
            .get_lowest_share_used()
            .total_cmp(&self.get_lowest_share_used())
            && c2 != std::cmp::Ordering::Equal
        {
            c2
        } else if let c3 = self
            .get_highest_local_priority()
            .cmp(&other.get_highest_local_priority())
            && c3 != std::cmp::Ordering::Equal
        {
            c3
        } else {
            other.get_lowest_build_id().cmp(&self.get_lowest_build_id())
        })
        .reverse()
    }

    pub(super) fn compare_with_rdeps(&self, other: &Self) -> std::cmp::Ordering {
        #[allow(irrefutable_let_patterns)]
        (if let c1 = self
            .get_highest_global_priority()
            .cmp(&other.get_highest_global_priority())
            && c1 != std::cmp::Ordering::Equal
        {
            c1
        } else if let c2 = other
            .get_lowest_share_used()
            .total_cmp(&self.get_lowest_share_used())
            && c2 != std::cmp::Ordering::Equal
        {
            c2
        } else if let c3 = self
            .step
            .atomic_state
            .rdeps_len
            .load(Ordering::Relaxed)
            .cmp(&other.step.atomic_state.rdeps_len.load(Ordering::Relaxed))
            && c3 != std::cmp::Ordering::Equal
        {
            c3
        } else if let c4 = self
            .get_highest_local_priority()
            .cmp(&other.get_highest_local_priority())
            && c4 != std::cmp::Ordering::Equal
        {
            c4
        } else {
            other.get_lowest_build_id().cmp(&self.get_lowest_build_id())
        })
        .reverse()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use db::models::BuildID;

    fn create_test_step(
        highest_global_priority: i32,
        highest_local_priority: i32,
        lowest_build_id: BuildID,
        lowest_share_used: f64,
        rdeps_len: u64,
    ) -> StepInfo {
        let step = Step::new(
            StorePath::from_base_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv").unwrap(),
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
    fn test_legacy_compare_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Less);
        assert_eq!(step2.legacy_compare(&step1), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_legacy_compare_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Less);
        assert_eq!(step2.legacy_compare(&step1), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_legacy_compare_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Less);
        assert_eq!(step2.legacy_compare(&step1), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_legacy_compare_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Less);
        assert_eq!(step2.legacy_compare(&step1), std::cmp::Ordering::Greater);
    }

    #[test]
    fn test_legacy_compare_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Equal);
    }

    #[test]
    fn test_compare_with_rdeps_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn test_compare_with_rdeps_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn test_compare_with_rdeps_rdeps_len() {
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 2, 1.0, 5);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn test_compare_with_rdeps_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn test_compare_with_rdeps_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn test_compare_with_rdeps_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Equal);
    }

    #[test]
    fn test_difference_between_compare_functions() {
        // Same global priority, share used, local priority, and build ID
        // But different rdeps_len - this should affect compare_with_rdeps but not legacy_compare
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 1, 1.0, 5);

        assert_eq!(step1.legacy_compare(&step2), std::cmp::Ordering::Equal);

        assert_eq!(step1.compare_with_rdeps(&step2), std::cmp::Ordering::Less);
        assert_eq!(
            step2.compare_with_rdeps(&step1),
            std::cmp::Ordering::Greater
        );
    }
}
