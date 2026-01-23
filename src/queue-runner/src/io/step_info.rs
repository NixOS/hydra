use std::sync::atomic::Ordering;

#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepInfo {
    drv_path: nix_utils::StorePath,
    already_scheduled: bool,
    runnable: bool,
    finished: bool,
    cancelled: bool,
    runnable_since: jiff::Timestamp,

    tries: u32,

    lowest_share_used: f64,
    highest_global_priority: i32,
    highest_local_priority: i32,
    lowest_build_id: db::models::BuildID,
}

impl From<std::sync::Arc<crate::state::StepInfo>> for StepInfo {
    fn from(item: std::sync::Arc<crate::state::StepInfo>) -> Self {
        Self {
            drv_path: item.step.get_drv_path().clone(),
            already_scheduled: item.get_already_scheduled(),
            runnable: item.step.get_runnable(),
            finished: item.step.get_finished(),
            cancelled: item.get_cancelled(),
            runnable_since: item.runnable_since,
            tries: item.step.atomic_state.tries.load(Ordering::Relaxed),
            lowest_share_used: item.get_lowest_share_used(),
            highest_global_priority: item.get_highest_global_priority(),
            highest_local_priority: item.get_highest_local_priority(),
            lowest_build_id: item.get_lowest_build_id(),
        }
    }
}
