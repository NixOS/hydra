use std::sync::{Arc, atomic::Ordering};

use ahash::{AHashMap, AHashSet};
use tokio::sync::mpsc;

use db::models::BuildID;

use super::System;
use super::build::RemoteBuild;
use crate::config::MachineFreeFn;
use crate::{
    config::MachineSortFn,
    server::grpc::runner_v1::{AbortMessage, BuildMessage, JoinMessage, runner_request},
};

#[derive(Debug, Clone, Copy)]
pub struct Pressure {
    pub avg10: f32,
    pub avg60: f32,
    pub avg300: f32,
    pub total: u64,
}

impl Pressure {
    fn new(msg: Option<crate::server::grpc::runner_v1::Pressure>) -> Option<Self> {
        msg.map(|v| Self {
            avg10: v.avg10,
            avg60: v.avg60,
            avg300: v.avg300,
            total: v.total,
        })
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
    total_step_time_ms: std::sync::atomic::AtomicU64,
    total_step_import_time_ms: std::sync::atomic::AtomicU64,
    total_step_build_time_ms: std::sync::atomic::AtomicU64,
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
    tmp_free_percent: atomic_float::AtomicF64,
    store_free_percent: atomic_float::AtomicF64,

    pub jobs_in_last_30s_start: std::sync::atomic::AtomicI64,
    pub jobs_in_last_30s_count: std::sync::atomic::AtomicU64,
}

impl Stats {
    pub fn new() -> Self {
        Self {
            current_jobs: 0.into(),
            nr_steps_done: 0.into(),
            total_step_time_ms: 0.into(),
            total_step_import_time_ms: 0.into(),
            total_step_build_time_ms: 0.into(),
            idle_since: (chrono::Utc::now().timestamp()).into(),
            last_failure: 0.into(),
            disabled_until: 0.into(),
            consecutive_failures: 0.into(),
            last_ping: 0.into(),

            load1: 0.0.into(),
            load5: 0.0.into(),
            load15: 0.0.into(),
            mem_usage: 0.into(),

            pressure: arc_swap::ArcSwapOption::from(None),
            tmp_free_percent: 0.0.into(),
            store_free_percent: 0.0.into(),

            jobs_in_last_30s_start: 0.into(),
            jobs_in_last_30s_count: 0.into(),
        }
    }

    pub fn store_current_jobs(&self, c: u64) {
        if c == 0 && self.idle_since.load(Ordering::Relaxed) == 0 {
            self.idle_since
                .store(chrono::Utc::now().timestamp(), Ordering::Relaxed);
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

    pub fn add_to_total_step_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_time_ms.fetch_add(v, Ordering::Relaxed);
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

    pub fn get_total_step_import_time_ms(&self) -> u64 {
        self.total_step_import_time_ms.load(Ordering::Relaxed)
    }

    pub fn add_to_total_step_import_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_import_time_ms
                .fetch_add(v, Ordering::Relaxed);
        }
    }

    pub fn get_idle_since(&self) -> i64 {
        self.idle_since.load(Ordering::Relaxed)
    }

    pub fn get_last_failure(&self) -> i64 {
        self.last_failure.load(Ordering::Relaxed)
    }

    pub fn store_last_failure_now(&self) {
        self.last_failure
            .store(chrono::Utc::now().timestamp(), Ordering::Relaxed);
        self.consecutive_failures.fetch_add(1, Ordering::Relaxed);
    }

    pub fn get_disabled_until(&self) -> i64 {
        self.disabled_until.load(Ordering::Relaxed)
    }

    pub fn get_consecutive_failures(&self) -> u64 {
        self.consecutive_failures.load(Ordering::Relaxed)
    }

    pub fn reset_consecutive_failures(&self) {
        self.consecutive_failures.store(0, Ordering::Relaxed);
    }

    pub fn get_last_ping(&self) -> i64 {
        self.last_ping.load(Ordering::Relaxed)
    }

    pub fn store_ping(&self, msg: &crate::server::grpc::runner_v1::PingMessage) {
        self.last_ping
            .store(chrono::Utc::now().timestamp(), Ordering::Relaxed);

        self.load1.store(msg.load1, Ordering::Relaxed);
        self.load5.store(msg.load5, Ordering::Relaxed);
        self.load15.store(msg.load15, Ordering::Relaxed);
        self.mem_usage.store(msg.mem_usage, Ordering::Relaxed);

        if let Some(p) = msg.pressure {
            self.pressure.store(Some(Arc::new(PressureState {
                cpu_some: Pressure::new(p.cpu_some),
                mem_some: Pressure::new(p.mem_some),
                mem_full: Pressure::new(p.mem_full),
                io_some: Pressure::new(p.io_some),
                io_full: Pressure::new(p.io_full),
                irq_full: Pressure::new(p.irq_full),
            })));
        }

        self.tmp_free_percent
            .store(msg.tmp_free_percent, Ordering::Relaxed);
        self.store_free_percent
            .store(msg.store_free_percent, Ordering::Relaxed);
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

    pub fn get_tmp_free_percent(&self) -> f64 {
        self.tmp_free_percent.load(Ordering::Relaxed)
    }

    pub fn get_store_free_percent(&self) -> f64 {
        self.store_free_percent.load(Ordering::Relaxed)
    }
}

struct MachinesInner {
    by_uuid: AHashMap<uuid::Uuid, Arc<Machine>>,
    // by_system is always sorted, as we insert sorted based on cpu score
    by_system: AHashMap<System, Vec<Arc<Machine>>>,
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
    supported_features: parking_lot::RwLock<AHashSet<String>>,
}

impl Machines {
    pub fn new() -> Self {
        Self {
            inner: parking_lot::RwLock::new(MachinesInner {
                by_uuid: AHashMap::new(),
                by_system: AHashMap::new(),
            }),
            supported_features: parking_lot::RwLock::new(AHashSet::new()),
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

    pub fn support_step(&self, s: &Arc<super::Step>) -> bool {
        // dup of machines.get_machine_for_system
        let inner = self.inner.read();
        let Some(system) = s.get_system() else {
            return false;
        };
        let features = s.get_required_features();
        if system == "builtin" {
            inner
                .by_uuid
                .values()
                .any(|m| m.supports_all_features(&features))
        } else {
            inner
                .by_system
                .get(&system)
                .is_some_and(|v| v.iter().any(|m| m.supports_all_features(&features)))
        }
    }

    #[allow(dead_code)]
    fn has_supported_features(&self, required_features: &[String]) -> bool {
        let supported_features = self.supported_features.read();
        required_features
            .iter()
            .all(|f| supported_features.contains(f))
    }

    fn reconstruct_supported_features(&self) {
        let all_supported_features = {
            let inner = self.inner.read();
            inner
                .by_uuid
                .values()
                .flat_map(|m| m.supported_features.clone())
                .collect::<AHashSet<_>>()
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
            if let Some(m) = inner.by_uuid.remove(&machine_id) {
                for system in &m.systems {
                    if let Some(v) = inner.by_system.get_mut(system) {
                        v.retain(|o| o.id != machine_id);
                    }
                }
                Some(m)
            } else {
                None
            }
        };
        self.reconstruct_supported_features();
        m
    }

    #[tracing::instrument(skip(self, machine_id))]
    pub fn get_machine_by_id(&self, machine_id: uuid::Uuid) -> Option<Arc<Machine>> {
        let inner = self.inner.read();
        inner.by_uuid.get(&machine_id).cloned()
    }

    #[tracing::instrument(skip(self, system))]
    pub fn get_machine_for_system(
        &self,
        system: &str,
        required_features: &[String],
        free_fn: MachineFreeFn,
    ) -> Option<Arc<Machine>> {
        // dup of machines.support_step
        let inner = self.inner.read();
        if system == "builtin" {
            inner
                .by_uuid
                .values()
                .find(|m| m.has_capacity(free_fn) && m.supports_all_features(required_features))
                .cloned()
        } else {
            inner.by_system.get(system).and_then(|machines| {
                machines
                    .iter()
                    .find(|m| m.has_capacity(free_fn) && m.supports_all_features(required_features))
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
}

#[derive(Debug, Clone)]
pub struct Job {
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
            path,
            resolved_drv,
            build_id,
            step_nr: 0,
            result: RemoteBuild::new(),
        }
    }
}

pub enum Message {
    BuildMessage {
        drv: nix_utils::StorePath,
        resolved_drv: Option<nix_utils::StorePath>,
        max_log_size: u64,
        max_silent_time: i32,
        build_timeout: i32,
    },
    AbortMessage {
        drv: nix_utils::StorePath,
    },
}

impl Message {
    pub fn into_request(self) -> crate::server::grpc::runner_v1::RunnerRequest {
        let msg = match self {
            Message::BuildMessage {
                drv,
                resolved_drv,
                max_log_size,
                max_silent_time,
                build_timeout,
            } => runner_request::Message::Build(BuildMessage {
                drv: drv.into_base_name(),
                resolved_drv: resolved_drv.map(nix_utils::StorePath::into_base_name),
                max_log_size,
                max_silent_time,
                build_timeout,
            }),
            Message::AbortMessage { drv } => runner_request::Message::Abort(AbortMessage {
                drv: drv.into_base_name(),
            }),
        };

        crate::server::grpc::runner_v1::RunnerRequest { message: Some(msg) }
    }
}

#[derive(Debug, Clone)]
pub struct Machine {
    pub id: uuid::Uuid,
    pub systems: Vec<System>,
    pub hostname: String,
    pub cpu_count: u32,
    pub bogomips: f32,
    pub speed_factor: f32,
    pub max_jobs: u32,
    pub tmp_avail_threshold: f64,
    pub store_avail_threshold: f64,
    pub load1_threshold: f32,
    pub cpu_psi_threshold: f32,
    pub mem_psi_threshold: f32,        // If None, dont consider this value
    pub io_psi_threshold: Option<f32>, // If None, dont consider this value
    pub total_mem: u64,
    pub supported_features: Vec<String>,
    pub mandatory_features: Vec<String>,
    pub cgroups: bool,
    pub joined_at: chrono::DateTime<chrono::Utc>,

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
    pub fn new(msg: JoinMessage, tx: mpsc::Sender<Message>) -> anyhow::Result<Self> {
        Ok(Self {
            id: msg.machine_id.parse()?,
            systems: msg.systems,
            hostname: msg.hostname,
            cpu_count: msg.cpu_count,
            bogomips: msg.bogomips,
            speed_factor: msg.speed_factor,
            max_jobs: msg.max_jobs,
            tmp_avail_threshold: msg.tmp_avail_threshold.into(),
            store_avail_threshold: msg.store_avail_threshold.into(),
            load1_threshold: msg.load1_threshold,
            cpu_psi_threshold: msg.cpu_psi_threshold,
            mem_psi_threshold: msg.mem_psi_threshold,
            io_psi_threshold: msg.io_psi_threshold,
            total_mem: msg.total_mem,
            supported_features: msg.supported_features,
            mandatory_features: msg.mandatory_features,
            cgroups: msg.cgroups,
            msg_queue: tx,
            joined_at: chrono::Utc::now(),
            stats: Arc::new(Stats::new()),
            jobs: Arc::new(parking_lot::RwLock::new(Vec::new())),
        })
    }

    #[tracing::instrument(skip(self, job, opts), err)]
    pub async fn build_drv(&self, job: Job, opts: &nix_utils::BuildOptions) -> anyhow::Result<()> {
        let drv = job.path.clone();
        self.msg_queue
            .send(Message::BuildMessage {
                drv,
                resolved_drv: job.resolved_drv.clone(),
                max_log_size: opts.get_max_log_size(),
                max_silent_time: opts.get_max_silent_time(),
                build_timeout: opts.get_build_timeout(),
            })
            .await?;

        if self.stats.jobs_in_last_30s_count.load(Ordering::Relaxed) == 0 {
            self.stats
                .jobs_in_last_30s_start
                .store(chrono::Utc::now().timestamp(), Ordering::Relaxed);
        }

        self.insert_job(job);
        self.stats
            .jobs_in_last_30s_count
            .fetch_add(1, Ordering::Relaxed);

        Ok(())
    }

    #[tracing::instrument(skip(self), fields(%drv), err)]
    pub async fn abort_build(&self, drv: &nix_utils::StorePath) -> anyhow::Result<()> {
        self.msg_queue
            .send(Message::AbortMessage {
                drv: drv.to_owned(),
            })
            .await?;

        self.remove_job(drv);
        Ok(())
    }

    pub fn has_dynamic_capacity(&self) -> bool {
        let pressure = self.stats.pressure.load();

        if let Some(cpu_some) = pressure.as_ref().and_then(|v| v.cpu_some) {
            if cpu_some.avg10 > self.cpu_psi_threshold {
                return false;
            }
            if let Some(mem_full) = pressure.as_ref().and_then(|v| v.mem_full) {
                if mem_full.avg10 > self.mem_psi_threshold {
                    return false;
                }
            }
            if let Some(threshold) = self.io_psi_threshold {
                if let Some(io_full) = pressure.as_ref().and_then(|v| v.io_full) {
                    if io_full.avg10 > threshold {
                        return false;
                    }
                }
            }
        } else if self.stats.get_load1() > self.load1_threshold {
            return false;
        }

        true
    }

    pub fn has_static_capacity(&self) -> bool {
        self.stats.get_current_jobs() < u64::from(self.max_jobs)
    }

    pub fn has_capacity(&self, free_fn: MachineFreeFn) -> bool {
        let now = chrono::Utc::now().timestamp();
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

        if self.stats.get_tmp_free_percent() < self.tmp_avail_threshold {
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

    pub fn supports_all_features(&self, features: &[String]) -> bool {
        // TODO: mandetory features
        features.iter().all(|f| self.supported_features.contains(f))
    }

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
        let job = jobs.iter().find(|j| &j.path == drv).cloned();
        job.map(|j| (j.build_id, j.step_nr))
    }

    #[tracing::instrument(skip(self, job))]
    fn insert_job(&self, job: Job) {
        let mut jobs = self.jobs.write();
        jobs.push(job);
        self.stats.store_current_jobs(jobs.len() as u64);
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    pub fn remove_job(&self, drv: &nix_utils::StorePath) -> Option<Job> {
        let mut jobs = self.jobs.write();
        let job = jobs.iter().find(|j| &j.path == drv).cloned();
        jobs.retain(|j| &j.path != drv);
        self.stats.store_current_jobs(jobs.len() as u64);
        self.stats.incr_nr_steps_done();

        {
            // if build finished fast we can subtract 1 here
            let now = chrono::Utc::now().timestamp();
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
