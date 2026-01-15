use std::sync::atomic::Ordering;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Build {
    id: db::models::BuildID,
    drv_path: nix_utils::StorePath,
    jobset_id: crate::state::JobsetID,
    name: String,
    timestamp: jiff::Timestamp,
    max_silent_time: i32,
    timeout: i32,
    local_priority: i32,
    global_priority: i32,
    finished_in_db: bool,
}

impl From<std::sync::Arc<crate::state::Build>> for Build {
    fn from(item: std::sync::Arc<crate::state::Build>) -> Self {
        Self {
            id: item.id,
            drv_path: item.drv_path.clone(),
            jobset_id: item.jobset_id,
            name: item.name.clone(),
            timestamp: item.timestamp,
            max_silent_time: item.max_silent_time,
            timeout: item.timeout,
            local_priority: item.local_priority,
            global_priority: item.global_priority.load(Ordering::Relaxed),
            finished_in_db: item.get_finished_in_db(),
        }
    }
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildPayload {
    pub drv: String,
    pub jobset_id: i32,
}
