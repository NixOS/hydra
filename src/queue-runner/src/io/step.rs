use std::sync::atomic::Ordering;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools)]
pub struct Step {
    drv_path: nix_utils::StorePath,
    runnable: bool,
    finished: bool,
    previous_failure: bool,

    created: bool,
    tries: u32,
    highest_global_priority: i32,
    highest_local_priority: i32,

    lowest_build_id: db::models::BuildID,
    deps_count: u64,
}

impl From<std::sync::Arc<crate::state::Step>> for Step {
    fn from(item: std::sync::Arc<crate::state::Step>) -> Self {
        Self {
            drv_path: item.get_drv_path().clone(),
            runnable: item.get_runnable(),
            finished: item.get_finished(),
            previous_failure: item.get_previous_failure(),
            created: item.atomic_state.get_created(),
            tries: item.atomic_state.tries.load(Ordering::Relaxed),
            highest_global_priority: item
                .atomic_state
                .highest_global_priority
                .load(Ordering::Relaxed),
            highest_local_priority: item
                .atomic_state
                .highest_local_priority
                .load(Ordering::Relaxed),
            lowest_build_id: item.atomic_state.lowest_build_id.load(Ordering::Relaxed),
            deps_count: item.get_deps_size(),
        }
    }
}
