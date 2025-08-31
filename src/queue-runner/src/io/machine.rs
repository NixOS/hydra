use std::sync::{Arc, atomic::Ordering};

use smallvec::SmallVec;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pressure {
    avg10: f32,
    avg60: f32,
    avg300: f32,
    total: u64,
}

impl From<crate::state::Pressure> for Pressure {
    fn from(v: crate::state::Pressure) -> Self {
        Self {
            avg10: v.avg10,
            avg60: v.avg60,
            avg300: v.avg300,
            total: v.total,
        }
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
    avg_step_upload_time_ms: u64,
    total_step_time_ms: u64,
    total_step_import_time_ms: u64,
    total_step_build_time_ms: u64,
    total_step_upload_time_ms: u64,
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
    build_dir_free_percent: f64,
    store_free_percent: f64,
    current_uploading_path_count: u64,
    current_downloading_path_count: u64,

    jobs_in_last_30s_start: i64,
    jobs_in_last_30s_count: u64,
    pub failed_builds: u64,
    pub succeeded_builds: u64,
}

impl MachineStats {
    fn from(item: &std::sync::Arc<crate::state::MachineStats>, now: i64) -> Self {
        let last_ping = item.get_last_ping();

        let nr_steps_done = item.get_nr_steps_done();
        let total_step_time_ms = item.get_total_step_time_ms();
        let total_step_import_time_ms = item.get_total_step_import_time_ms();
        let total_step_build_time_ms = item.get_total_step_build_time_ms();
        let total_step_upload_time_ms = item.get_total_step_upload_time_ms();
        let (
            avg_step_time_ms,
            avg_step_import_time_ms,
            avg_step_build_time_ms,
            avg_step_upload_time_ms,
        ) = if nr_steps_done > 0 {
            (
                total_step_time_ms / nr_steps_done,
                total_step_import_time_ms / nr_steps_done,
                total_step_build_time_ms / nr_steps_done,
                total_step_upload_time_ms / nr_steps_done,
            )
        } else {
            (0, 0, 0, 0)
        };

        Self {
            current_jobs: item.get_current_jobs(),
            nr_steps_done,
            avg_step_time_ms,
            avg_step_import_time_ms,
            avg_step_build_time_ms,
            avg_step_upload_time_ms,
            total_step_time_ms,
            total_step_import_time_ms,
            total_step_build_time_ms,
            total_step_upload_time_ms,
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
                cpu_some: p.cpu_some.map(Into::into),
                mem_some: p.mem_some.map(Into::into),
                mem_full: p.mem_full.map(Into::into),
                io_some: p.io_some.map(Into::into),
                io_full: p.io_full.map(Into::into),
                irq_full: p.irq_full.map(Into::into),
            }),
            build_dir_free_percent: item.get_build_dir_free_percent(),
            store_free_percent: item.get_store_free_percent(),
            current_uploading_path_count: item.get_current_uploading_path_count(),
            current_downloading_path_count: item.get_current_downloading_count(),
            jobs_in_last_30s_start: item.jobs_in_last_30s_start.load(Ordering::Relaxed),
            jobs_in_last_30s_count: item.jobs_in_last_30s_count.load(Ordering::Relaxed),
            failed_builds: item.get_failed_builds(),
            succeeded_builds: item.get_succeeded_builds(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools)]
pub struct Machine {
    systems: SmallVec<[crate::state::System; 4]>,
    hostname: String,
    uptime: f64,
    cpu_count: u32,
    bogomips: f32,
    speed_factor: f32,
    max_jobs: u32,
    build_dir_avail_threshold: f64,
    store_avail_threshold: f64,
    load1_threshold: f32,
    cpu_psi_threshold: f32,
    mem_psi_threshold: f32,
    io_psi_threshold: Option<f32>,
    score: f32,
    total_mem: u64,
    supported_features: SmallVec<[String; 8]>,
    mandatory_features: SmallVec<[String; 4]>,
    cgroups: bool,
    substituters: SmallVec<[String; 4]>,
    use_substitutes: bool,
    nix_version: String,
    stats: MachineStats,
    jobs: Vec<nix_utils::StorePath>,

    has_capacity: bool,
    has_dynamic_capacity: bool,
    has_static_capacity: bool,
}

impl Machine {
    #[must_use]
    pub fn from_state(
        item: &Arc<crate::state::Machine>,
        sort_fn: crate::config::MachineSortFn,
        free_fn: crate::config::MachineFreeFn,
    ) -> Self {
        let jobs = { item.jobs.read().iter().map(|j| j.path.clone()).collect() };
        let time = jiff::Timestamp::now();
        Self {
            systems: item.systems.clone(),
            uptime: (time - item.joined_at)
                .total(jiff::Unit::Second)
                .unwrap_or_default(),
            hostname: item.hostname.clone(),
            cpu_count: item.cpu_count,
            bogomips: item.bogomips,
            speed_factor: item.speed_factor,
            max_jobs: item.max_jobs,
            build_dir_avail_threshold: item.build_dir_avail_threshold,
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
            substituters: item.substituters.clone(),
            use_substitutes: item.use_substitutes,
            nix_version: item.nix_version.clone(),

            stats: MachineStats::from(&item.stats, time.as_second()),
            jobs,
            has_capacity: item.has_capacity(free_fn),
            has_dynamic_capacity: item.has_dynamic_capacity(),
            has_static_capacity: item.has_static_capacity(),
        }
    }
}
