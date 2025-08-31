use std::sync::{Arc, atomic::Ordering};

use ahash::AHashMap;
use anyhow::Context as _;

use db::models::BuildID;
use nix_utils::BaseStore as _;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Empty {}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Error {
    pub error: String,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildPayload {
    pub drv: String,
    pub jobset_id: i32,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pressure {
    avg10: f32,
    avg60: f32,
    avg300: f32,
    total: u64,
}

impl Pressure {
    pub fn new(item: Option<&crate::state::Pressure>) -> Option<Self> {
        item.map(|v| Self {
            avg10: v.avg10,
            avg60: v.avg60,
            avg300: v.avg300,
            total: v.total,
        })
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PressureState {
    cpu_some: Option<Pressure>,
    mem_some: Option<Pressure>,
    mem_full: Option<Pressure>,
    io_some: Option<Pressure>,
    io_full: Option<Pressure>,
    irq_full: Option<Pressure>,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineStats {
    current_jobs: u64,
    nr_steps_done: u64,
    avg_step_time_ms: u64,
    avg_step_import_time_ms: u64,
    avg_step_build_time_ms: u64,
    total_step_time_ms: u64,
    total_step_import_time_ms: u64,
    total_step_build_time_ms: u64,
    idle_since: i64,

    last_failure: i64,
    disabled_until: i64,
    consecutive_failures: u64,
    last_ping: i64,
    since_last_ping: i64,

    load1: f32,
    load5: f32,
    load15: f32,
    mem_usage: u64,
    pressure: Option<PressureState>,
    tmp_free_percent: f64,
    store_free_percent: f64,

    jobs_in_last_30s_start: i64,
    jobs_in_last_30s_count: u64,
}

impl MachineStats {
    fn from(item: &std::sync::Arc<crate::state::MachineStats>, now: i64) -> Self {
        let last_ping = item.get_last_ping();

        let nr_steps_done = item.get_nr_steps_done();
        let total_step_time_ms = item.get_total_step_time_ms();
        let total_step_import_time_ms = item.get_total_step_import_time_ms();
        let total_step_build_time_ms = item.get_total_step_build_time_ms();
        let (avg_step_time_ms, avg_step_import_time_ms, avg_step_build_time_ms) =
            if nr_steps_done > 0 {
                (
                    total_step_time_ms / nr_steps_done,
                    total_step_import_time_ms / nr_steps_done,
                    total_step_build_time_ms / nr_steps_done,
                )
            } else {
                (0, 0, 0)
            };

        Self {
            current_jobs: item.get_current_jobs(),
            nr_steps_done,
            avg_step_time_ms,
            avg_step_import_time_ms,
            avg_step_build_time_ms,
            total_step_time_ms,
            total_step_import_time_ms,
            total_step_build_time_ms,
            idle_since: item.get_idle_since(),
            last_failure: item.get_last_failure(),
            disabled_until: item.get_disabled_until(),
            consecutive_failures: item.get_consecutive_failures(),
            last_ping,
            since_last_ping: now - last_ping,
            load1: item.get_load1(),
            load5: item.get_load5(),
            load15: item.get_load15(),
            mem_usage: item.get_mem_usage(),
            pressure: item.pressure.load().as_ref().map(|p| PressureState {
                cpu_some: Pressure::new(p.cpu_some.as_ref()),
                mem_some: Pressure::new(p.mem_some.as_ref()),
                mem_full: Pressure::new(p.mem_full.as_ref()),
                io_some: Pressure::new(p.io_some.as_ref()),
                io_full: Pressure::new(p.io_full.as_ref()),
                irq_full: Pressure::new(p.irq_full.as_ref()),
            }),
            tmp_free_percent: item.get_tmp_free_percent(),
            store_free_percent: item.get_store_free_percent(),
            jobs_in_last_30s_start: item.jobs_in_last_30s_start.load(Ordering::Relaxed),
            jobs_in_last_30s_count: item.jobs_in_last_30s_count.load(Ordering::Relaxed),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools)]
pub struct Machine {
    systems: Vec<crate::state::System>,
    hostname: String,
    uptime: f64,
    cpu_count: u32,
    bogomips: f32,
    speed_factor: f32,
    max_jobs: u32,
    tmp_avail_threshold: f64,
    store_avail_threshold: f64,
    load1_threshold: f32,
    cpu_psi_threshold: f32,
    mem_psi_threshold: f32,
    io_psi_threshold: Option<f32>,
    score: f32,
    total_mem: u64,
    supported_features: Vec<String>,
    mandatory_features: Vec<String>,
    cgroups: bool,
    stats: MachineStats,
    jobs: Vec<nix_utils::StorePath>,

    has_capacity: bool,
    has_dynamic_capacity: bool,
    has_static_capacity: bool,
}

impl Machine {
    pub fn from_state(
        item: &Arc<crate::state::Machine>,
        sort_fn: crate::config::MachineSortFn,
        free_fn: crate::config::MachineFreeFn,
    ) -> Self {
        let jobs = { item.jobs.read().iter().map(|j| j.path.clone()).collect() };
        let time = chrono::Utc::now();
        Self {
            systems: item.systems.clone(),
            uptime: (time - item.joined_at).as_seconds_f64(),
            hostname: item.hostname.clone(),
            cpu_count: item.cpu_count,
            bogomips: item.bogomips,
            speed_factor: item.speed_factor,
            max_jobs: item.max_jobs,
            tmp_avail_threshold: item.tmp_avail_threshold,
            store_avail_threshold: item.store_avail_threshold,
            load1_threshold: item.load1_threshold,
            cpu_psi_threshold: item.cpu_psi_threshold,
            mem_psi_threshold: item.mem_psi_threshold,
            io_psi_threshold: item.io_psi_threshold,
            score: item.score(sort_fn),
            total_mem: item.total_mem,
            supported_features: item.supported_features.clone(),
            mandatory_features: item.mandatory_features.clone(),
            cgroups: item.cgroups,
            stats: MachineStats::from(&item.stats, time.timestamp()),
            jobs,
            has_capacity: item.has_capacity(free_fn),
            has_dynamic_capacity: item.has_dynamic_capacity(),
            has_static_capacity: item.has_static_capacity(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
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

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_field_names)]
pub struct MemoryStats {
    current_bytes: u64,
    peak_bytes: u64,
    swap_current_bytes: u64,
    zswap_current_bytes: u64,
}

impl MemoryStats {
    fn new(cgroups_path: &std::path::Path) -> anyhow::Result<Self> {
        Ok(Self {
            current_bytes: std::fs::read_to_string(cgroups_path.join("memory.current"))?
                .trim()
                .parse()
                .context("memory current parsing failed")?,
            peak_bytes: std::fs::read_to_string(cgroups_path.join("memory.peak"))?
                .trim()
                .parse()
                .context("memory peak parsing failed")?,
            swap_current_bytes: std::fs::read_to_string(cgroups_path.join("memory.swap.current"))?
                .trim()
                .parse()
                .context("swap parsing failed")?,
            zswap_current_bytes: std::fs::read_to_string(
                cgroups_path.join("memory.zswap.current"),
            )?
            .trim()
            .parse()
            .context("zswap parsing failed")?,
        })
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IoStats {
    total_read_bytes: u64,
    total_write_bytes: u64,
}

impl IoStats {
    fn new(cgroups_path: &std::path::Path) -> anyhow::Result<Self> {
        let mut total_read_bytes: u64 = 0;
        let mut total_write_bytes: u64 = 0;

        let contents = std::fs::read_to_string(cgroups_path.join("io.stat"))?;
        for line in contents.lines() {
            for part in line.split_whitespace() {
                if part.starts_with("rbytes=") {
                    total_read_bytes += part
                        .split('=')
                        .nth(1)
                        .and_then(|v| v.trim().parse().ok())
                        .unwrap_or(0);
                } else if part.starts_with("wbytes=") {
                    total_write_bytes += part
                        .split('=')
                        .nth(1)
                        .and_then(|v| v.trim().parse().ok())
                        .unwrap_or(0);
                }
            }
        }

        Ok(Self {
            total_read_bytes,
            total_write_bytes,
        })
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_field_names)]
pub struct CpuStats {
    usage_usec: u128,
    user_usec: u128,
    system_usec: u128,
}

impl CpuStats {
    fn new(cgroups_path: &std::path::Path) -> anyhow::Result<Self> {
        let contents = std::fs::read_to_string(cgroups_path.join("cpu.stat"))?;

        let mut usage_usec: u128 = 0;
        let mut user_usec: u128 = 0;
        let mut system_usec: u128 = 0;

        for line in contents.lines() {
            if line.starts_with("usage_usec") {
                usage_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            } else if line.starts_with("user_usec") {
                user_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            } else if line.starts_with("system_usec") {
                system_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            }
        }
        Ok(Self {
            usage_usec,
            user_usec,
            system_usec,
        })
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CgroupStats {
    memory: MemoryStats,
    io: IoStats,
    cpu: CpuStats,
}

impl CgroupStats {
    fn new(me: &procfs::process::Process) -> anyhow::Result<Self> {
        let cgroups_pathname = format!(
            "/sys/fs/cgroup/{}",
            me.cgroups()?
                .0
                .first()
                .ok_or(anyhow::anyhow!("cgroup information is missing in process."))?
                .pathname
        );
        let cgroups_path = std::path::Path::new(&cgroups_pathname);
        if !cgroups_path.exists() {
            return Err(anyhow::anyhow!("cgroups directory does not exists."));
        }

        Ok(Self {
            memory: MemoryStats::new(cgroups_path)?,
            io: IoStats::new(cgroups_path)?,
            cpu: CpuStats::new(cgroups_path)?,
        })
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Process {
    pid: i32,
    vsize_bytes: u64,
    rss_bytes: u64,
    shared_bytes: u64,
    cgroup: Option<CgroupStats>,
}

impl Process {
    fn new() -> Option<Self> {
        let me = procfs::process::Process::myself().ok()?;
        let page_size = procfs::page_size();
        let statm = me.statm().ok()?;
        let vsize = statm.size * page_size;
        let rss = statm.resident * page_size;
        let shared = statm.shared * page_size;
        Some(Self {
            pid: me.pid,
            vsize_bytes: vsize,
            rss_bytes: rss,
            shared_bytes: shared,
            cgroup: match CgroupStats::new(&me) {
                Ok(v) => Some(v),
                Err(e) => {
                    log::error!("failed to cgroups stats: {e}");
                    None
                }
            },
        })
    }
}

#[derive(Debug, serde::Serialize)]
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
    fn new(v: &nix_utils::StoreStats) -> Self {
        #[allow(clippy::cast_precision_loss)]
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
            nar_compression_savings: if v.nar_write_bytes > 0 {
                1.0 - (v.nar_write_compressed_bytes as f64 / v.nar_write_bytes as f64)
            } else {
                0.0
            },
            nar_compression_speed: if v.nar_write_compression_time_ms > 0 {
                v.nar_write_bytes as f64 / v.nar_write_compression_time_ms as f64 * 1000.0
                    / (1024.0 * 1024.0)
            } else {
                0.0
            },
        }
    }
}

#[derive(Debug, serde::Serialize)]
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
    fn new(v: &nix_utils::S3Stats) -> Self {
        #[allow(clippy::cast_precision_loss)]
        Self {
            put: v.put,
            put_bytes: v.put_bytes,
            put_time_ms: v.put_time_ms,
            put_speed: if v.put_time_ms > 0 {
                v.put_bytes as f64 / v.put_time_ms as f64 * 1000.0 / (1024.0 * 1024.0)
            } else {
                0.0
            },
            get: v.get,
            get_bytes: v.get_bytes,
            get_time_ms: v.get_time_ms,
            get_speed: if v.get_time_ms > 0 {
                v.get_bytes as f64 / v.get_time_ms as f64 * 1000.0 / (1024.0 * 1024.0)
            } else {
                0.0
            },
            head: v.head,
            cost_dollar_approx: (v.get as f64 + v.head as f64) / 10000.0 * 0.004
                + v.put as f64 / 1000.0 * 0.005
                + v.get_bytes as f64 / (1024.0 * 1024.0 * 1024.0) * 0.09,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueRunnerStats {
    status: &'static str,
    time: chrono::DateTime<chrono::Utc>,
    uptime: f64,
    proc: Option<Process>,
    supported_features: Vec<String>,

    build_count: usize,
    jobset_count: usize,
    step_count: usize,
    runnable_count: usize,
    queue_stats: AHashMap<crate::state::System, BuildQueueStats>,

    queue_checks_started: u64,
    queue_build_loads: u64,
    queue_steps_created: u64,
    queue_checks_early_exits: u64,
    queue_checks_finished: u64,

    dispatcher_time_spent_running: u64,
    dispatcher_time_spent_waiting: u64,

    queue_monitor_time_spent_running: u64,
    queue_monitor_time_spent_waiting: u64,

    nr_builds_read: i64,
    build_read_time_ms: i64,
    nr_builds_unfinished: i64,
    nr_builds_done: i64,
    nr_steps_started: i64,
    nr_steps_done: i64,
    nr_steps_building: i64,
    nr_steps_waiting: i64,
    nr_steps_runnable: i64,
    nr_steps_unfinished: i64,
    nr_unsupported_steps: i64,
    nr_unsupported_steps_aborted: i64,
    nr_substitutes_started: i64,
    nr_substitutes_failed: i64,
    nr_substitutes_succeeded: i64,
    nr_retries: i64,
    max_nr_retries: i64,
    avg_step_time_ms: i64,
    avg_step_import_time_ms: i64,
    avg_step_build_time_ms: i64,
    total_step_time_ms: i64,
    total_step_import_time_ms: i64,
    total_step_build_time_ms: i64,
    nr_queue_wakeups: i64,
    nr_dispatcher_wakeups: i64,
    dispatch_time_ms: i64,
    machines_total: i64,
    machines_in_use: i64,
}

impl QueueRunnerStats {
    pub async fn new(state: Arc<crate::state::State>) -> Self {
        let build_count = state.get_nr_builds_unfinished();
        let jobset_count = { state.jobsets.read().len() };
        let step_count = state.get_nr_steps_unfinished();
        let runnable_count = state.get_nr_runnable();
        let queue_stats = {
            let queues = state.queues.read().await;
            queues
                .iter()
                .map(|(system, queue)| (system.clone(), queue.get_stats().into()))
                .collect()
        };

        state.metrics.refresh_dynamic_metrics(&state).await;

        let time = chrono::Utc::now();
        Self {
            status: "up",
            time,
            uptime: (time - state.started_at).as_seconds_f64(),
            proc: Process::new(),
            supported_features: state.machines.get_supported_features(),
            build_count,
            jobset_count,
            step_count,
            runnable_count,
            queue_stats,
            queue_checks_started: state.metrics.queue_checks_started.get(),
            queue_build_loads: state.metrics.queue_build_loads.get(),
            queue_steps_created: state.metrics.queue_steps_created.get(),
            queue_checks_early_exits: state.metrics.queue_checks_early_exits.get(),
            queue_checks_finished: state.metrics.queue_checks_finished.get(),

            dispatcher_time_spent_running: state.metrics.dispatcher_time_spent_running.get(),
            dispatcher_time_spent_waiting: state.metrics.dispatcher_time_spent_waiting.get(),

            queue_monitor_time_spent_running: state.metrics.queue_monitor_time_spent_running.get(),
            queue_monitor_time_spent_waiting: state.metrics.queue_monitor_time_spent_waiting.get(),

            nr_builds_read: state.metrics.nr_builds_read.get(),
            build_read_time_ms: state.metrics.build_read_time_ms.get(),
            nr_builds_unfinished: state.metrics.nr_builds_unfinished.get(),
            nr_builds_done: state.metrics.nr_builds_done.get(),
            nr_steps_started: state.metrics.nr_steps_started.get(),
            nr_steps_done: state.metrics.nr_steps_done.get(),
            nr_steps_building: state.metrics.nr_steps_building.get(),
            nr_steps_waiting: state.metrics.nr_steps_waiting.get(),
            nr_steps_runnable: state.metrics.nr_steps_runnable.get(),
            nr_steps_unfinished: state.metrics.nr_steps_unfinished.get(),
            nr_unsupported_steps: state.metrics.nr_unsupported_steps.get(),
            nr_unsupported_steps_aborted: state.metrics.nr_unsupported_steps_aborted.get(),
            nr_substitutes_started: state.metrics.nr_substitutes_started.get(),
            nr_substitutes_failed: state.metrics.nr_substitutes_failed.get(),
            nr_substitutes_succeeded: state.metrics.nr_substitutes_succeeded.get(),
            nr_retries: state.metrics.nr_retries.get(),
            max_nr_retries: state.metrics.max_nr_retries.get(),
            avg_step_time_ms: state.metrics.avg_step_time_ms.get(),
            avg_step_import_time_ms: state.metrics.avg_step_import_time_ms.get(),
            avg_step_build_time_ms: state.metrics.avg_step_build_time_ms.get(),
            total_step_time_ms: state.metrics.total_step_time_ms.get(),
            total_step_import_time_ms: state.metrics.total_step_import_time_ms.get(),
            total_step_build_time_ms: state.metrics.total_step_build_time_ms.get(),
            nr_queue_wakeups: state.metrics.nr_queue_wakeups.get(),
            nr_dispatcher_wakeups: state.metrics.nr_dispatcher_wakeups.get(),
            dispatch_time_ms: state.metrics.dispatch_time_ms.get(),
            machines_total: state.metrics.machines_total.get(),
            machines_in_use: state.metrics.machines_in_use.get(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DumpResponse {
    queue_runner: QueueRunnerStats,
    machines: AHashMap<String, Machine>,
    jobsets: AHashMap<String, Jobset>,
    store: AHashMap<String, StoreStats>,
    s3: AHashMap<String, S3Stats>,
}

impl DumpResponse {
    pub fn new(
        queue_runner: QueueRunnerStats,
        machines: AHashMap<String, Machine>,
        jobsets: AHashMap<String, Jobset>,
        local_store: &nix_utils::LocalStore,
        remote_stores: &[nix_utils::RemoteStore],
    ) -> Self {
        let mut store_stats = remote_stores
            .iter()
            .filter_map(|s| {
                Some((
                    s.base_uri.clone(),
                    StoreStats::new(&s.get_store_stats().ok()?),
                ))
            })
            .collect::<AHashMap<_, _>>();
        if let Ok(s) = local_store.get_store_stats() {
            store_stats.insert("local".into(), StoreStats::new(&s));
        }

        Self {
            queue_runner,
            machines,
            jobsets,
            store: store_stats,
            s3: remote_stores
                .iter()
                .filter_map(|s| Some((s.base_uri.clone(), S3Stats::new(&s.get_s3_stats().ok()?))))
                .collect(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachinesResponse {
    machines: AHashMap<String, Machine>,
    machines_count: usize,
}

impl MachinesResponse {
    pub fn new(machines: AHashMap<String, Machine>) -> Self {
        Self {
            machines_count: machines.len(),
            machines,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Jobset {
    id: crate::state::JobsetID,
    project_name: String,
    name: String,

    seconds: i64,
    shares: u32,
}

impl From<std::sync::Arc<crate::state::Jobset>> for Jobset {
    fn from(item: std::sync::Arc<crate::state::Jobset>) -> Self {
        Self {
            id: item.id,
            project_name: item.project_name.clone(),
            name: item.name.clone(),
            seconds: item.get_seconds(),
            shares: item.get_shares(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobsetsResponse {
    jobsets: AHashMap<String, Jobset>,
    jobset_count: usize,
}

impl JobsetsResponse {
    pub fn new(jobsets: AHashMap<String, Jobset>) -> Self {
        Self {
            jobset_count: jobsets.len(),
            jobsets,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Build {
    id: BuildID,
    drv_path: nix_utils::StorePath,
    jobset_id: crate::state::JobsetID,
    name: String,
    timestamp: chrono::DateTime<chrono::Utc>,
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

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildsResponse {
    builds: Vec<Build>,
    build_count: usize,
}

impl BuildsResponse {
    pub fn new(builds: Vec<Build>) -> Self {
        Self {
            build_count: builds.len(),
            builds,
        }
    }
}

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

    lowest_build_id: BuildID,
    deps_count: usize,
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

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepsResponse {
    steps: Vec<Step>,
    step_count: usize,
}

impl StepsResponse {
    pub fn new(steps: Vec<Step>) -> Self {
        Self {
            step_count: steps.len(),
            steps,
        }
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepInfo {
    drv_path: nix_utils::StorePath,
    already_scheduled: bool,
    runnable: bool,
    finished: bool,
    cancelled: bool,
    runnable_since: chrono::DateTime<chrono::Utc>,

    tries: u32,

    lowest_share_used: f64,
    highest_global_priority: i32,
    highest_local_priority: i32,
    lowest_build_id: BuildID,
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
            lowest_share_used: item.lowest_share_used,
            highest_global_priority: item.highest_global_priority,
            highest_local_priority: item.highest_local_priority,
            lowest_build_id: item.lowest_build_id,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueResponse {
    queues: AHashMap<String, Vec<StepInfo>>,
}

impl QueueResponse {
    pub fn new(queues: AHashMap<String, Vec<StepInfo>>) -> Self {
        Self { queues }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepInfoResponse {
    steps: Vec<StepInfo>,
    step_count: usize,
}

impl StepInfoResponse {
    pub fn new(steps: Vec<StepInfo>) -> Self {
        Self {
            step_count: steps.len(),
            steps,
        }
    }
}
