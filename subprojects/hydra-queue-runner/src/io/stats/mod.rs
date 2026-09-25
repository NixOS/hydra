#[cfg_attr(target_os = "linux", path = "linux.rs")]
#[cfg_attr(not(target_os = "linux"), path = "other.rs")]
mod process;

use process::ProcessExtra;

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Process {
    pid: i32,
    #[serde(flatten)]
    extra: ProcessExtra,
}

impl Process {
    pub fn new() -> Option<Self> {
        Some(Self {
            pid: std::process::id().try_into().ok()?,
            extra: ProcessExtra::new()?,
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildQueueStats {
    active_runnable: u64,
    total_runnable: u64,
    nr_runnable_waiting: u64,
    nr_runnable_disabled: u64,
    avg_runnable_time: u64,
    wait_time_ms: u64,
}

impl From<crate::state::BuildQueueStats> for BuildQueueStats {
    fn from(v: crate::state::BuildQueueStats) -> Self {
        Self {
            active_runnable: v.active_runnable,
            total_runnable: v.total_runnable,
            nr_runnable_waiting: v.nr_runnable_waiting,
            nr_runnable_disabled: v.nr_runnable_disabled,
            avg_runnable_time: v.avg_runnable_time,
            wait_time_ms: v.wait_time,
        }
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreStats {
    nar_info_read: u64,
    nar_info_read_averted: u64,
    nar_info_missing: u64,
    nar_info_write: u64,
    path_info_cache_size: u64,
    nar_read: u64,
    nar_read_bytes: u64,
    nar_read_compressed_bytes: u64,
    nar_write: u64,
    nar_write_averted: u64,
    nar_write_bytes: u64,
    nar_write_compressed_bytes: u64,
    nar_write_compression_time_ms: u64,
    nar_compression_savings: f64,
    nar_compression_speed: f64,
}

impl StoreStats {
    #[must_use]
    pub fn new(v: &StoreStats) -> Self {
        Self {
            nar_info_read: v.nar_info_read,
            nar_info_read_averted: v.nar_info_read_averted,
            nar_info_missing: v.nar_info_missing,
            nar_info_write: v.nar_info_write,
            path_info_cache_size: v.path_info_cache_size,
            nar_read: v.nar_read,
            nar_read_bytes: v.nar_read_bytes,
            nar_read_compressed_bytes: v.nar_read_compressed_bytes,
            nar_write: v.nar_write,
            nar_write_averted: v.nar_write_averted,
            nar_write_bytes: v.nar_write_bytes,
            nar_write_compressed_bytes: v.nar_write_compressed_bytes,
            nar_write_compression_time_ms: v.nar_write_compression_time_ms,
            nar_compression_savings: 0.0, // not available via daemon protocol
            nar_compression_speed: 0.0,   // not available via daemon protocol
        }
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct S3Stats {
    put: u64,
    put_bytes: u64,
    put_time_ms: u64,
    put_speed: f64,
    get: u64,
    get_bytes: u64,
    get_time_ms: u64,
    get_speed: f64,
    head: u64,
    cost_dollar_approx: f64,
}

impl S3Stats {
    #[must_use]
    pub fn new(v: &binary_cache::S3Stats) -> Self {
        Self {
            put: v.put,
            put_bytes: v.put_bytes,
            put_time_ms: v.put_time_ms,
            put_speed: v.put_speed(),
            get: v.get,
            get_bytes: v.get_bytes,
            get_time_ms: v.get_time_ms,
            get_speed: v.get_speed(),
            head: v.head,
            cost_dollar_approx: v.cost_dollar_approx(),
        }
    }
}
