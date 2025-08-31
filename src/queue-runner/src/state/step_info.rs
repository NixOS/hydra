use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use db::models::BuildID;
use nix_utils::BaseStore as _;

use super::Step;

pub struct StepInfo {
    pub step: Arc<Step>,
    pub resolved_drv_path: Option<nix_utils::StorePath>,
    already_scheduled: AtomicBool,
    cancelled: AtomicBool,
    pub runnable_since: jiff::Timestamp,
    lowest_share_used: atomic_float::AtomicF64,
}

impl StepInfo {
    pub async fn new(store: &nix_utils::LocalStore, step: Arc<Step>) -> Self {
        Self {
            resolved_drv_path: store.try_resolve_drv(step.get_drv_path()).await,
            already_scheduled: false.into(),
            cancelled: false.into(),
            runnable_since: step.get_runnable_since(),
            lowest_share_used: step.get_lowest_share_used().into(),
            step,
        }
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
    use super::*;
    use db::models::BuildID;

    fn create_test_step(
        highest_global_priority: i32,
        highest_local_priority: i32,
        lowest_build_id: BuildID,
        lowest_share_used: f64,
        rdeps_len: u64,
    ) -> StepInfo {
        let step = Step::new(nix_utils::StorePath::new(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv",
        ));

        step.atomic_state.highest_global_priority.store(
            highest_global_priority,
            std::sync::atomic::Ordering::Relaxed,
        );
        step.atomic_state
            .highest_local_priority
            .store(highest_local_priority, std::sync::atomic::Ordering::Relaxed);
        step.atomic_state
            .lowest_build_id
            .store(lowest_build_id, std::sync::atomic::Ordering::Relaxed);
        step.atomic_state
            .rdeps_len
            .store(rdeps_len, std::sync::atomic::Ordering::Relaxed);

        StepInfo {
            step,
            resolved_drv_path: None,
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
