use std::sync::{Arc, atomic::Ordering};

use hashbrown::{HashMap, HashSet};
use smallvec::SmallVec;
use tokio::sync::mpsc;

use db::models::BuildID;

use super::{RemoteBuild, System};
use crate::config::{MachineFreeFn, MachineSortFn};
use crate::server::grpc::runner_v1::{AbortMessage, BuildMessage, JoinMessage, runner_request};

#[derive(Debug, Clone, Copy)]
pub struct Pressure {
    pub avg10: f32,
    pub avg60: f32,
    pub avg300: f32,
    pub total: u64,
}

impl From<crate::server::grpc::runner_v1::Pressure> for Pressure {
    fn from(v: crate::server::grpc::runner_v1::Pressure) -> Self {
        Self {
            avg10: v.avg10,
            avg60: v.avg60,
            avg300: v.avg300,
            total: v.total,
        }
    }
}

#[derive(Debug)]
pub struct PressureState {
    pub cpu_some: Option<Pressure>,
    pub mem_some: Option<Pressure>,
    pub mem_full: Option<Pressure>,
    pub io_some: Option<Pressure>,
    pub io_full: Option<Pressure>,
    pub irq_full: Option<Pressure>,
}

#[derive(Debug)]
pub struct Stats {
    current_jobs: std::sync::atomic::AtomicU64,
    nr_steps_done: std::sync::atomic::AtomicU64,
    failed_builds: std::sync::atomic::AtomicU64,
    succeeded_builds: std::sync::atomic::AtomicU64,

    total_step_time_ms: std::sync::atomic::AtomicU64,
    total_step_import_time_ms: std::sync::atomic::AtomicU64,
    total_step_build_time_ms: std::sync::atomic::AtomicU64,
    total_step_upload_time_ms: std::sync::atomic::AtomicU64,
    idle_since: std::sync::atomic::AtomicI64,

    last_failure: std::sync::atomic::AtomicI64,
    disabled_until: std::sync::atomic::AtomicI64,
    consecutive_failures: std::sync::atomic::AtomicU64,
    last_ping: std::sync::atomic::AtomicI64,

    load1: atomic_float::AtomicF32,
    load5: atomic_float::AtomicF32,
    load15: atomic_float::AtomicF32,
    mem_usage: std::sync::atomic::AtomicU64,
    pub pressure: arc_swap::ArcSwapOption<PressureState>,
    build_dir_free_percent: atomic_float::AtomicF64,
    store_free_percent: atomic_float::AtomicF64,
    current_uploading_path_count: std::sync::atomic::AtomicU64,
    current_downloading_count: std::sync::atomic::AtomicU64,

    pub jobs_in_last_30s_start: std::sync::atomic::AtomicI64,
    pub jobs_in_last_30s_count: std::sync::atomic::AtomicU64,
}

impl Default for Stats {
    fn default() -> Self {
        Self::new()
    }
}

impl Stats {
    #[must_use]
    pub fn new() -> Self {
        Self {
            current_jobs: 0.into(),
            nr_steps_done: 0.into(),
            failed_builds: 0.into(),
            succeeded_builds: 0.into(),

            total_step_time_ms: 0.into(),
            total_step_import_time_ms: 0.into(),
            total_step_build_time_ms: 0.into(),
            total_step_upload_time_ms: 0.into(),
            idle_since: (jiff::Timestamp::now().as_second()).into(),
            last_failure: 0.into(),
            disabled_until: 0.into(),
            consecutive_failures: 0.into(),
            last_ping: 0.into(),

            load1: 0.0.into(),
            load5: 0.0.into(),
            load15: 0.0.into(),
            mem_usage: 0.into(),

            pressure: arc_swap::ArcSwapOption::from(None),
            build_dir_free_percent: 0.0.into(),
            store_free_percent: 0.0.into(),
            current_uploading_path_count: 0.into(),
            current_downloading_count: 0.into(),

            jobs_in_last_30s_start: 0.into(),
            jobs_in_last_30s_count: 0.into(),
        }
    }

    pub fn store_current_jobs(&self, c: u64) {
        if c == 0 && self.idle_since.load(Ordering::Relaxed) == 0 {
            self.idle_since
                .store(jiff::Timestamp::now().as_second(), Ordering::Relaxed);
        } else {
            self.idle_since.store(0, Ordering::Relaxed);
        }

        self.current_jobs.store(c, Ordering::Relaxed);
    }

    pub fn get_current_jobs(&self) -> u64 {
        self.current_jobs.load(Ordering::Relaxed)
    }

    pub fn get_nr_steps_done(&self) -> u64 {
        self.nr_steps_done.load(Ordering::Relaxed)
    }

    pub fn incr_nr_steps_done(&self) {
        self.nr_steps_done.fetch_add(1, Ordering::Relaxed);
    }

    pub fn get_total_step_time_ms(&self) -> u64 {
        self.total_step_time_ms.load(Ordering::Relaxed)
    }

    pub fn get_total_step_import_time_ms(&self) -> u64 {
        self.total_step_import_time_ms.load(Ordering::Relaxed)
    }

    fn add_to_total_step_import_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_import_time_ms
                .fetch_add(v, Ordering::Relaxed);
        }
    }

    pub fn get_total_step_build_time_ms(&self) -> u64 {
        self.total_step_build_time_ms.load(Ordering::Relaxed)
    }

    pub fn add_to_total_step_build_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_build_time_ms
                .fetch_add(v, Ordering::Relaxed);
        }
    }

    pub fn get_total_step_upload_time_ms(&self) -> u64 {
        self.total_step_upload_time_ms.load(Ordering::Relaxed)
    }

    fn add_to_total_step_upload_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_upload_time_ms
                .fetch_add(v, Ordering::Relaxed);
        }
    }

    pub fn get_idle_since(&self) -> i64 {
        self.idle_since.load(Ordering::Relaxed)
    }

    pub fn get_last_failure(&self) -> i64 {
        self.last_failure.load(Ordering::Relaxed)
    }

    pub fn get_disabled_until(&self) -> i64 {
        self.disabled_until.load(Ordering::Relaxed)
    }

    pub fn get_consecutive_failures(&self) -> u64 {
        self.consecutive_failures.load(Ordering::Relaxed)
    }

    pub fn get_failed_builds(&self) -> u64 {
        self.failed_builds.load(Ordering::Relaxed)
    }

    pub fn get_succeeded_builds(&self) -> u64 {
        self.succeeded_builds.load(Ordering::Relaxed)
    }

    pub fn track_build_success(&self, timings: super::build::BuildTimings, total_step_time: u64) {
        self.succeeded_builds.fetch_add(1, Ordering::Relaxed);
        self.add_to_total_step_import_time_ms(timings.import_elapsed.as_millis());
        self.add_to_total_step_build_time_ms(timings.build_elapsed.as_millis());
        self.add_to_total_step_upload_time_ms(timings.upload_elapsed.as_millis());
        self.total_step_time_ms
            .fetch_add(total_step_time, Ordering::Relaxed);
        self.consecutive_failures.store(0, Ordering::Relaxed);
    }

    pub fn track_build_failure(&self, timings: super::build::BuildTimings, total_step_time: u64) {
        self.failed_builds.fetch_add(1, Ordering::Relaxed);
        self.add_to_total_step_import_time_ms(timings.import_elapsed.as_millis());
        self.add_to_total_step_build_time_ms(timings.build_elapsed.as_millis());
        self.add_to_total_step_upload_time_ms(timings.upload_elapsed.as_millis());
        self.total_step_time_ms
            .fetch_add(total_step_time, Ordering::Relaxed);
        self.last_failure
            .store(jiff::Timestamp::now().as_second(), Ordering::Relaxed);
        self.consecutive_failures.fetch_add(1, Ordering::Relaxed);
    }

    pub fn get_last_ping(&self) -> i64 {
        self.last_ping.load(Ordering::Relaxed)
    }

    pub fn store_ping(&self, msg: &crate::server::grpc::runner_v1::PingMessage) {
        self.last_ping
            .store(jiff::Timestamp::now().as_second(), Ordering::Relaxed);

        self.load1.store(msg.load1, Ordering::Relaxed);
        self.load5.store(msg.load5, Ordering::Relaxed);
        self.load15.store(msg.load15, Ordering::Relaxed);
        self.mem_usage.store(msg.mem_usage, Ordering::Relaxed);

        if let Some(p) = msg.pressure {
            self.pressure.store(Some(Arc::new(PressureState {
                cpu_some: p.cpu_some.map(Into::into),
                mem_some: p.mem_some.map(Into::into),
                mem_full: p.mem_full.map(Into::into),
                io_some: p.io_some.map(Into::into),
                io_full: p.io_full.map(Into::into),
                irq_full: p.irq_full.map(Into::into),
            })));
        }

        self.build_dir_free_percent
            .store(msg.build_dir_free_percent, Ordering::Relaxed);
        self.store_free_percent
            .store(msg.store_free_percent, Ordering::Relaxed);

        self.current_uploading_path_count
            .store(msg.current_uploading_path_count, Ordering::Relaxed);
        self.current_downloading_count
            .store(msg.current_downloading_path_count, Ordering::Relaxed);
    }

    pub fn get_load1(&self) -> f32 {
        self.load1.load(Ordering::Relaxed)
    }

    pub fn get_load5(&self) -> f32 {
        self.load5.load(Ordering::Relaxed)
    }

    pub fn get_load15(&self) -> f32 {
        self.load15.load(Ordering::Relaxed)
    }

    pub fn get_mem_usage(&self) -> u64 {
        self.mem_usage.load(Ordering::Relaxed)
    }

    pub fn get_build_dir_free_percent(&self) -> f64 {
        self.build_dir_free_percent.load(Ordering::Relaxed)
    }

    pub fn get_store_free_percent(&self) -> f64 {
        self.store_free_percent.load(Ordering::Relaxed)
    }

    pub fn get_current_uploading_path_count(&self) -> u64 {
        self.current_uploading_path_count.load(Ordering::Relaxed)
    }

    pub fn get_current_downloading_count(&self) -> u64 {
        self.current_downloading_count.load(Ordering::Relaxed)
    }
}

struct MachinesInner {
    by_uuid: HashMap<uuid::Uuid, Arc<Machine>>,
    // by_system is always sorted, as we insert sorted based on cpu score
    by_system: HashMap<System, Vec<Arc<Machine>>>,
}

impl MachinesInner {
    fn sort(&mut self, sort_fn: MachineSortFn) {
        for machines in self.by_system.values_mut() {
            machines.sort_by(|a, b| {
                let r = a.score(sort_fn).total_cmp(&b.score(sort_fn)).reverse();
                if r.is_eq() {
                    // if score is the same then we do a tiebreaker on current jobs
                    a.stats.get_current_jobs().cmp(&b.stats.get_current_jobs())
                } else {
                    r
                }
            });
        }
    }
}

pub struct Machines {
    inner: parking_lot::RwLock<MachinesInner>,
    supported_features: parking_lot::RwLock<HashSet<String>>,
}

impl Default for Machines {
    fn default() -> Self {
        Self::new()
    }
}

impl Machines {
    pub fn new() -> Self {
        Self {
            inner: parking_lot::RwLock::new(MachinesInner {
                by_uuid: HashMap::with_capacity(10),
                by_system: HashMap::with_capacity(10),
            }),
            supported_features: parking_lot::RwLock::new(HashSet::new()),
        }
    }

    pub fn sort(&self, sort_fn: MachineSortFn) {
        let mut inner = self.inner.write();
        inner.sort(sort_fn);
    }

    pub fn get_supported_features(&self) -> Vec<String> {
        let supported_features = self.supported_features.read();
        supported_features.iter().cloned().collect()
    }

    fn reconstruct_supported_features(&self) {
        let all_supported_features = {
            let inner = self.inner.read();
            inner
                .by_uuid
                .values()
                .flat_map(|m| m.supported_features.clone())
                .collect::<HashSet<_>>()
        };

        {
            let mut supported_features = self.supported_features.write();
            *supported_features = all_supported_features;
        }
    }

    #[tracing::instrument(skip(self, machine, sort_fn))]
    pub fn insert_machine(&self, machine: Machine, sort_fn: MachineSortFn) -> uuid::Uuid {
        let machine_id = machine.id;
        {
            let mut inner = self.inner.write();
            let machine = Arc::new(machine);

            inner.by_uuid.insert(machine_id, machine.clone());
            {
                for system in &machine.systems {
                    let v = inner.by_system.entry(system.clone()).or_default();
                    v.push(machine.clone());
                }
            }
            inner.sort(sort_fn);
        }
        self.reconstruct_supported_features();
        machine_id
    }

    #[tracing::instrument(skip(self, machine_id))]
    pub fn remove_machine(&self, machine_id: uuid::Uuid) -> Option<Arc<Machine>> {
        let m = {
            let mut inner = self.inner.write();
            inner.by_uuid.remove(&machine_id).map_or_else(
                || None,
                |m| {
                    for system in &m.systems {
                        if let Some(v) = inner.by_system.get_mut(system) {
                            v.retain(|o| o.id != machine_id);
                        }
                    }
                    Some(m)
                },
            )
        };
        self.reconstruct_supported_features();
        m
    }

    #[tracing::instrument(skip(self, machine_id))]
    pub fn get_machine_by_id(&self, machine_id: uuid::Uuid) -> Option<Arc<Machine>> {
        let inner = self.inner.read();
        inner.by_uuid.get(&machine_id).cloned()
    }

    pub fn support_step(&self, s: &Arc<super::Step>) -> bool {
        let Some(system) = s.get_system() else {
            return false;
        };
        self.get_machine_for_system(&system, &s.get_required_features(), None)
            .is_some()
    }

    #[tracing::instrument(skip(self, system))]
    pub fn get_machine_for_system(
        &self,
        system: &str,
        required_features: &[String],
        free_fn: Option<MachineFreeFn>,
    ) -> Option<Arc<Machine>> {
        // dup of machines.support_step
        let inner = self.inner.read();
        if system == "builtin" {
            inner
                .by_uuid
                .values()
                .find(|m| {
                    free_fn.is_none_or(|free_fn| m.has_capacity(free_fn))
                        && m.mandatory_features
                            .iter()
                            .all(|s| required_features.contains(s))
                        && m.supports_all_features(required_features)
                })
                .cloned()
        } else {
            inner.by_system.get(system).and_then(|machines| {
                machines
                    .iter()
                    .find(|m| {
                        free_fn.is_none_or(|free_fn| m.has_capacity(free_fn))
                            && m.mandatory_features
                                .iter()
                                .all(|s| required_features.contains(s))
                            && m.supports_all_features(required_features)
                    })
                    .cloned()
            })
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn get_all_machines(&self) -> Vec<Arc<Machine>> {
        let inner = self.inner.read();
        inner.by_uuid.values().cloned().collect()
    }

    #[tracing::instrument(skip(self))]
    pub fn get_machine_count(&self) -> usize {
        self.inner.read().by_uuid.len()
    }

    #[tracing::instrument(skip(self))]
    pub fn get_machine_count_in_use(&self) -> usize {
        self.inner
            .read()
            .by_uuid
            .iter()
            .filter(|(_, v)| v.stats.get_current_jobs() > 0)
            .count()
    }

    #[tracing::instrument(skip(self))]
    pub async fn publish_new_config(&self, cfg: ConfigUpdate) {
        let machines = {
            self.inner
                .read()
                .by_uuid
                .values()
                .cloned()
                .collect::<Vec<_>>()
        };

        for m in machines {
            let _ = m.publish_config_update(cfg).await;
        }
    }
}

#[derive(Debug, Clone)]
pub struct Job {
    pub internal_build_id: uuid::Uuid,
    pub path: nix_utils::StorePath,
    pub resolved_drv: Option<nix_utils::StorePath>,
    pub build_id: BuildID,
    pub step_nr: i32,
    pub result: RemoteBuild,
}

impl Job {
    pub fn new(
        build_id: BuildID,
        path: nix_utils::StorePath,
        resolved_drv: Option<nix_utils::StorePath>,
    ) -> Self {
        Self {
            internal_build_id: uuid::Uuid::new_v4(),
            path,
            resolved_drv,
            build_id,
            step_nr: 0,
            result: RemoteBuild::new(),
        }
    }
}

pub struct PresignedUrlOpts {
    pub upload_debug_info: bool,
}

impl From<PresignedUrlOpts> for crate::server::grpc::runner_v1::PresignedUploadOpts {
    fn from(value: PresignedUrlOpts) -> Self {
        Self {
            upload_debug_info: value.upload_debug_info,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ConfigUpdate {
    pub max_concurrent_downloads: u32,
}

pub enum Message {
    ConfigUpdate(ConfigUpdate),
    BuildMessage {
        build_id: uuid::Uuid,
        drv: nix_utils::StorePath,
        resolved_drv: Option<nix_utils::StorePath>,
        max_log_size: u64,
        max_silent_time: i32,
        build_timeout: i32,
        presigned_url_opts: Option<PresignedUrlOpts>,
    },
    AbortMessage {
        build_id: uuid::Uuid,
    },
}

impl Message {
    pub fn into_request(self) -> crate::server::grpc::runner_v1::RunnerRequest {
        let msg = match self {
            Self::ConfigUpdate(m) => runner_request::Message::ConfigUpdate(
                crate::server::grpc::runner_v1::ConfigUpdate {
                    max_concurrent_downloads: m.max_concurrent_downloads,
                },
            ),
            Self::BuildMessage {
                build_id,
                drv,
                resolved_drv,
                max_log_size,
                max_silent_time,
                build_timeout,
                presigned_url_opts,
            } => runner_request::Message::Build(BuildMessage {
                build_id: build_id.to_string(),
                drv: drv.into_base_name(),
                resolved_drv: resolved_drv.map(nix_utils::StorePath::into_base_name),
                max_log_size,
                max_silent_time,
                build_timeout,
                presigned_url_opts: presigned_url_opts.map(Into::into),
            }),
            Self::AbortMessage { build_id } => runner_request::Message::Abort(AbortMessage {
                build_id: build_id.to_string(),
            }),
        };

        crate::server::grpc::runner_v1::RunnerRequest { message: Some(msg) }
    }
}

#[derive(Debug, Clone)]
pub struct Machine {
    pub id: uuid::Uuid,
    pub systems: SmallVec<[System; 4]>,
    pub hostname: String,
    pub cpu_count: u32,
    pub bogomips: f32,
    pub speed_factor: f32,
    pub max_jobs: u32,
    pub build_dir_avail_threshold: f64,
    pub store_avail_threshold: f64,
    pub load1_threshold: f32,
    pub cpu_psi_threshold: f32,
    pub mem_psi_threshold: f32,        // If None, dont consider this value
    pub io_psi_threshold: Option<f32>, // If None, dont consider this value
    pub total_mem: u64,
    pub supported_features: SmallVec<[String; 8]>,
    pub mandatory_features: SmallVec<[String; 4]>,
    pub cgroups: bool,
    pub substituters: SmallVec<[String; 4]>,
    pub use_substitutes: bool,
    pub nix_version: String,
    pub joined_at: jiff::Timestamp,

    msg_queue: mpsc::Sender<Message>,
    pub stats: Arc<Stats>,
    pub jobs: Arc<parking_lot::RwLock<Vec<Job>>>,
}

impl std::fmt::Display for Machine {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "Machine: [systems={:?} hostname={} cpu_count={} bogomips={:.2} speed_factor={:.2} max_jobs={} total_mem={:.2} supported_features={:?} cgroups={} joined_at={}]",
            self.systems,
            self.hostname,
            self.cpu_count,
            self.bogomips,
            self.speed_factor,
            self.max_jobs,
            byte_unit::Byte::from_u64(self.total_mem).get_adjusted_unit(byte_unit::Unit::GB),
            self.supported_features,
            self.cgroups,
            self.joined_at,
        )
    }
}

impl Machine {
    #[tracing::instrument(skip(tx), err)]
    pub fn new(
        msg: JoinMessage,
        tx: mpsc::Sender<Message>,
        use_presigned_uploads: bool,
        forced_substituters: &[String],
    ) -> anyhow::Result<Self> {
        if use_presigned_uploads && !forced_substituters.is_empty() {
            if !msg.use_substitutes {
                return Err(anyhow::anyhow!(
                    "Forced_substituters is configured but builder doesnt use substituters. This is an issue because presigned uploads are enabled",
                ));
            }

            for forced_sub in forced_substituters {
                if !msg.substituters.contains(forced_sub) {
                    return Err(anyhow::anyhow!(
                        "Builder missing required substituter '{}'. Available: {:?}",
                        forced_sub,
                        msg.substituters
                    ));
                }
            }
        }

        Ok(Self {
            id: msg.machine_id.parse()?,
            systems: msg.systems.into(),
            hostname: msg.hostname,
            cpu_count: msg.cpu_count,
            bogomips: msg.bogomips,
            speed_factor: msg.speed_factor,
            max_jobs: msg.max_jobs,
            build_dir_avail_threshold: msg.build_dir_avail_threshold.into(),
            store_avail_threshold: msg.store_avail_threshold.into(),
            load1_threshold: msg.load1_threshold,
            cpu_psi_threshold: msg.cpu_psi_threshold,
            mem_psi_threshold: msg.mem_psi_threshold,
            io_psi_threshold: msg.io_psi_threshold,
            total_mem: msg.total_mem,
            supported_features: msg.supported_features.into(),
            mandatory_features: msg.mandatory_features.into(),
            cgroups: msg.cgroups,
            substituters: msg.substituters.into(),
            use_substitutes: msg.use_substitutes,
            nix_version: msg.nix_version,

            msg_queue: tx,
            joined_at: jiff::Timestamp::now(),
            stats: Arc::new(Stats::new()),
            jobs: Arc::new(parking_lot::RwLock::new(Vec::new())),
        })
    }

    #[tracing::instrument(
        skip(self, job, opts, presigned_url_opts),
        fields(build_id=job.build_id, step_nr=job.step_nr),
        err,
    )]
    pub async fn build_drv(
        &self,
        job: Job,
        opts: &nix_utils::BuildOptions,
        presigned_url_opts: Option<PresignedUrlOpts>,
    ) -> anyhow::Result<()> {
        let drv = job.path.clone();
        self.msg_queue
            .send(Message::BuildMessage {
                build_id: job.internal_build_id,
                drv,
                resolved_drv: job.resolved_drv.clone(),
                max_log_size: opts.get_max_log_size(),
                max_silent_time: opts.get_max_silent_time(),
                build_timeout: opts.get_build_timeout(),
                presigned_url_opts,
            })
            .await?;

        if self.stats.jobs_in_last_30s_count.load(Ordering::Relaxed) == 0 {
            self.stats
                .jobs_in_last_30s_start
                .store(jiff::Timestamp::now().as_second(), Ordering::Relaxed);
        }

        self.insert_job(job);
        self.stats
            .jobs_in_last_30s_count
            .fetch_add(1, Ordering::Relaxed);

        Ok(())
    }

    #[tracing::instrument(skip(self), fields(build_id=%build_id), err)]
    pub async fn abort_build(&self, build_id: uuid::Uuid) -> anyhow::Result<()> {
        self.msg_queue
            .send(Message::AbortMessage { build_id })
            .await?;

        // dont remove job from machine now, we will do that when the job is set to failed/cancelled
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn publish_config_update(&self, change: ConfigUpdate) -> anyhow::Result<()> {
        self.msg_queue.send(Message::ConfigUpdate(change)).await?;
        Ok(())
    }

    #[must_use]
    pub fn has_dynamic_capacity(&self) -> bool {
        let pressure = self.stats.pressure.load();

        if let Some(cpu_some) = pressure.as_ref().and_then(|v| v.cpu_some) {
            if cpu_some.avg10 > self.cpu_psi_threshold {
                return false;
            }
            if let Some(mem_full) = pressure.as_ref().and_then(|v| v.mem_full)
                && mem_full.avg10 > self.mem_psi_threshold
            {
                return false;
            }
            if let Some(threshold) = self.io_psi_threshold
                && let Some(io_full) = pressure.as_ref().and_then(|v| v.io_full)
                && io_full.avg10 > threshold
            {
                return false;
            }
        } else if self.stats.get_load1() > self.load1_threshold {
            return false;
        }

        true
    }

    #[must_use]
    pub fn has_static_capacity(&self) -> bool {
        self.stats.get_current_jobs() < u64::from(self.max_jobs)
    }

    #[must_use]
    pub fn has_capacity(&self, free_fn: MachineFreeFn) -> bool {
        let now = jiff::Timestamp::now().as_second();
        let jobs_in_last_30s_start = self.stats.jobs_in_last_30s_start.load(Ordering::Relaxed);
        let jobs_in_last_30s_count = self.stats.jobs_in_last_30s_count.load(Ordering::Relaxed);

        // ensure that we dont submit more than 4 jobs in 30s
        if now <= (jobs_in_last_30s_start + 30)
            && jobs_in_last_30s_count >= 4
            // ensure that we havent already finished some of them, because then its fine again
            && self.stats.get_current_jobs() >= 4
        {
            return false;
        } else if now > (jobs_in_last_30s_start + 30) {
            // reset count
            self.stats
                .jobs_in_last_30s_start
                .store(0, Ordering::Relaxed);
            self.stats
                .jobs_in_last_30s_count
                .store(0, Ordering::Relaxed);
        }

        if self.stats.get_build_dir_free_percent() < self.build_dir_avail_threshold {
            return false;
        }

        if self.stats.get_store_free_percent() < self.store_avail_threshold {
            return false;
        }

        match free_fn {
            MachineFreeFn::Dynamic => self.has_dynamic_capacity(),
            MachineFreeFn::DynamicWithMaxJobLimit => {
                self.has_dynamic_capacity() && self.has_static_capacity()
            }
            MachineFreeFn::Static => self.has_static_capacity(),
        }
    }

    #[must_use]
    pub fn supports_all_features(&self, features: &[String]) -> bool {
        // TODO: mandetory features
        features.iter().all(|f| self.supported_features.contains(f))
    }

    #[must_use]
    pub fn score(&self, sort_fn: MachineSortFn) -> f32 {
        match sort_fn {
            MachineSortFn::SpeedFactorOnly => self.speed_factor,
            MachineSortFn::CpuCoreCountWithSpeedFactor =>
            {
                #[allow(clippy::cast_precision_loss)]
                (self.speed_factor * (self.cpu_count as f32))
            }
            MachineSortFn::BogomipsWithSpeedFactor => {
                let bogomips = if self.bogomips > 1. {
                    self.bogomips
                } else {
                    1.0
                };
                #[allow(clippy::cast_precision_loss)]
                (self.speed_factor * bogomips * (self.cpu_count as f32))
            }
        }
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    pub fn get_build_id_and_step_nr(&self, drv: &nix_utils::StorePath) -> Option<(i32, i32)> {
        let jobs = self.jobs.read();
        jobs.iter()
            .find(|j| &j.path == drv)
            .map(|j| (j.build_id, j.step_nr))
    }

    #[tracing::instrument(skip(self), fields(%build_id))]
    pub fn get_build_id_and_step_nr_by_uuid(&self, build_id: uuid::Uuid) -> Option<(i32, i32)> {
        let jobs = self.jobs.read();
        jobs.iter()
            .find(|j| j.internal_build_id == build_id)
            .map(|j| (j.build_id, j.step_nr))
    }

    #[tracing::instrument(skip(self), fields(%build_id))]
    pub fn get_job_drv_for_build_id(&self, build_id: uuid::Uuid) -> Option<nix_utils::StorePath> {
        let jobs = self.jobs.read();
        jobs.iter()
            .find(|j| j.internal_build_id == build_id)
            .map(|v| v.path.clone())
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    pub fn get_internal_build_id_for_drv(&self, drv: &nix_utils::StorePath) -> Option<uuid::Uuid> {
        let jobs = self.jobs.read();
        jobs.iter()
            .find(|j| &j.path == drv)
            .map(|v| v.internal_build_id)
    }

    #[tracing::instrument(skip(self, job))]
    fn insert_job(&self, job: Job) {
        let mut jobs = self.jobs.write();
        jobs.push(job);
        self.stats.store_current_jobs(jobs.len() as u64);
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    pub fn remove_job(&self, drv: &nix_utils::StorePath) -> Option<Job> {
        let job = {
            let mut jobs = self.jobs.write();
            let job = jobs.iter().find(|j| &j.path == drv).cloned();
            jobs.retain(|j| &j.path != drv);
            self.stats.incr_nr_steps_done();
            self.stats.store_current_jobs(jobs.len() as u64);
            job
        };

        {
            // if build finished fast we can subtract 1 here
            let now = jiff::Timestamp::now().as_second();
            let jobs_in_last_30s_start = self.stats.jobs_in_last_30s_start.load(Ordering::Relaxed);

            if now <= (jobs_in_last_30s_start + 30) {
                self.stats
                    .jobs_in_last_30s_count
                    .fetch_sub(1, Ordering::Relaxed);
            }
        }

        job
    }
}
