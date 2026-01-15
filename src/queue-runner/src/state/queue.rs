use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};

use hashbrown::{HashMap, HashSet};
use smallvec::SmallVec;

use super::{StepInfo, System};
use crate::config::StepSortFn;

#[derive(Debug)]
pub struct BuildQueue {
    // Note: ensure that this stays private
    jobs: parking_lot::RwLock<Vec<Weak<StepInfo>>>,

    active_runnable: AtomicU64,
    total_runnable: AtomicU64,
    nr_runnable_waiting: AtomicU64,
    nr_runnable_disabled: AtomicU64,
    avg_runnable_time: AtomicU64,
    wait_time_ms: AtomicU64,
}

#[derive(Debug)]
pub struct BuildQueueStats {
    pub active_runnable: u64,
    pub total_runnable: u64,
    pub nr_runnable_waiting: u64,
    pub nr_runnable_disabled: u64,
    pub avg_runnable_time: u64,
    pub wait_time: u64,
}

impl BuildQueue {
    fn new() -> Self {
        Self {
            jobs: parking_lot::RwLock::new(Vec::new()),
            active_runnable: 0.into(),
            total_runnable: 0.into(),
            nr_runnable_waiting: 0.into(),
            nr_runnable_disabled: 0.into(),
            avg_runnable_time: 0.into(),
            wait_time_ms: 0.into(),
        }
    }

    pub fn set_nr_runnable_waiting(&self, v: u64) {
        self.nr_runnable_waiting.store(v, Ordering::Relaxed);
    }

    pub fn set_nr_runnable_disabled(&self, v: u64) {
        self.nr_runnable_disabled.store(v, Ordering::Relaxed);
    }

    fn incr_active(&self) {
        self.active_runnable.fetch_add(1, Ordering::Relaxed);
    }

    fn decr_active(&self) {
        self.active_runnable.fetch_sub(1, Ordering::Relaxed);
    }

    #[tracing::instrument(skip(self, jobs))]
    fn insert_new_jobs(
        &self,
        jobs: Vec<Weak<StepInfo>>,
        now: &jiff::Timestamp,
        sort_fn: StepSortFn,
    ) -> u64 {
        let mut current_jobs = self.jobs.write();
        let mut wait_time_ms = 0u64;

        for j in jobs {
            if let Some(owned) = j.upgrade() {
                // this ensures we only ever have each step once
                // so ensure that current_jobs is never written anywhere else
                // this should never continue as jobs, should already exclude duplicates
                if current_jobs
                    .iter()
                    .filter_map(std::sync::Weak::upgrade)
                    .any(|v| v.step.get_drv_path() == owned.step.get_drv_path())
                {
                    continue;
                }

                // runnable since is always > now
                wait_time_ms += u64::try_from(now.duration_since(owned.runnable_since).as_millis())
                    .unwrap_or_default();
                current_jobs.push(j);
            }
        }
        self.wait_time_ms.fetch_add(wait_time_ms, Ordering::Relaxed);

        // only keep valid pointers
        drop(current_jobs);
        self.scrube_jobs();
        self.sort_jobs(sort_fn)
    }

    #[tracing::instrument(skip(self))]
    pub fn sort_jobs(&self, sort_fn: StepSortFn) -> u64 {
        let start_time = std::time::Instant::now();
        let cmp_fn = match sort_fn {
            StepSortFn::Legacy => StepInfo::legacy_compare,
            StepSortFn::WithRdeps => StepInfo::compare_with_rdeps,
        };

        {
            let mut current_jobs = self.jobs.write();
            for job in current_jobs.iter_mut() {
                let Some(job) = job.upgrade() else { continue };
                job.update_internal_stats();
            }

            current_jobs.sort_by(|a, b| {
                let a = a.upgrade();
                let b = b.upgrade();
                match (a, b) {
                    (Some(a), Some(b)) => cmp_fn(a.as_ref(), b.as_ref()),
                    (Some(_), None) => std::cmp::Ordering::Greater,
                    (None, Some(_)) => std::cmp::Ordering::Less,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            });
        }
        u64::try_from(start_time.elapsed().as_millis()).unwrap_or_default()
    }

    #[tracing::instrument(skip(self))]
    pub fn scrube_jobs(&self) {
        let mut current_jobs = self.jobs.write();
        current_jobs.retain(|v| v.upgrade().is_some());
        self.total_runnable
            .store(current_jobs.len() as u64, Ordering::Relaxed);
    }

    pub fn clone_inner(&self) -> Vec<Weak<StepInfo>> {
        (*self.jobs.read()).clone()
    }

    pub fn get_stats(&self) -> BuildQueueStats {
        BuildQueueStats {
            active_runnable: self.active_runnable.load(Ordering::Relaxed),
            total_runnable: self.total_runnable.load(Ordering::Relaxed),
            nr_runnable_waiting: self.nr_runnable_waiting.load(Ordering::Relaxed),
            nr_runnable_disabled: self.nr_runnable_disabled.load(Ordering::Relaxed),
            avg_runnable_time: self.avg_runnable_time.load(Ordering::Relaxed),
            wait_time: self.wait_time_ms.load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone)]
pub struct ScheduledItem {
    pub step_info: Arc<StepInfo>,
    pub build_queue: Arc<BuildQueue>,
    pub machine: Arc<super::Machine>,
}

impl ScheduledItem {
    const fn new(
        step_info: Arc<StepInfo>,
        build_queue: Arc<BuildQueue>,
        machine: Arc<super::Machine>,
    ) -> Self {
        Self {
            step_info,
            build_queue,
            machine,
        }
    }
}

pub struct InnerQueues {
    // flat list of all step infos in queues, owning those steps inner queue dont own them
    jobs: HashMap<nix_utils::StorePath, Arc<StepInfo>>,
    inner: HashMap<System, Arc<BuildQueue>>,
    #[allow(clippy::type_complexity)]
    scheduled: parking_lot::RwLock<HashMap<nix_utils::StorePath, ScheduledItem>>,
}

impl Default for InnerQueues {
    fn default() -> Self {
        Self::new()
    }
}

impl InnerQueues {
    fn new() -> Self {
        Self {
            jobs: HashMap::with_capacity(1000),
            inner: HashMap::with_capacity(4),
            scheduled: parking_lot::RwLock::new(HashMap::with_capacity(100)),
        }
    }

    #[tracing::instrument(skip(self, jobs))]
    fn insert_new_jobs<S: Into<String> + std::fmt::Debug>(
        &mut self,
        system: S,
        jobs: Vec<StepInfo>,
        now: &jiff::Timestamp,
        sort_fn: StepSortFn,
    ) -> u64 {
        let mut submit_jobs: Vec<Weak<StepInfo>> = Vec::new();
        for j in jobs {
            let j = Arc::new(j);
            // we need to check that get_finished is not true!
            // the reason for this is that while a job is currently being proccessed for finished
            // it can be resubmitted into the queues.
            // to ensure that this does not block everything we need to ensure that it doesnt land
            // here.
            if !self.jobs.contains_key(j.step.get_drv_path()) && !j.step.get_finished() {
                self.jobs
                    .insert(j.step.get_drv_path().to_owned(), j.clone());
                submit_jobs.push(Arc::downgrade(&j));
            }
        }

        let queue = self
            .inner
            .entry(system.into())
            .or_insert_with(|| Arc::new(BuildQueue::new()));
        // queues are sorted afterwards
        queue.insert_new_jobs(submit_jobs, now, sort_fn)
    }

    #[tracing::instrument(skip(self))]
    fn ensure_queues_for_systems(&mut self, systems: &[System]) {
        for system in systems {
            self.inner
                .entry(system.clone())
                .or_insert_with(|| Arc::new(BuildQueue::new()));
        }
    }

    #[tracing::instrument(skip(self))]
    fn remove_all_weak_pointer(&self) {
        for queue in self.inner.values() {
            queue.scrube_jobs();
        }
    }

    fn clone_inner(&self) -> HashMap<System, Arc<BuildQueue>> {
        self.inner.clone()
    }

    #[tracing::instrument(skip(self, step, queue))]
    fn add_job_to_scheduled(
        &self,
        step: &Arc<StepInfo>,
        queue: &Arc<BuildQueue>,
        machine: Arc<super::Machine>,
    ) {
        self.scheduled.write().insert(
            step.step.get_drv_path().to_owned(),
            ScheduledItem::new(step.clone(), queue.clone(), machine),
        );
        step.set_already_scheduled(true);
        queue.incr_active();
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    fn remove_job_from_scheduled(&self, drv: &nix_utils::StorePath) -> Option<ScheduledItem> {
        let item = self.scheduled.write().remove(drv)?;
        item.step_info.set_already_scheduled(false);
        item.build_queue.decr_active();
        Some(item)
    }

    fn remove_job_by_path(&mut self, drv: &nix_utils::StorePath) {
        if self.jobs.remove(drv).is_none() {
            tracing::error!("Failed to remove stepinfo drv={drv} from jobs!");
        }
    }

    #[tracing::instrument(skip(self, stepinfo, queue))]
    fn remove_job(&mut self, stepinfo: &Arc<StepInfo>, queue: &Arc<BuildQueue>) {
        if self.jobs.remove(stepinfo.step.get_drv_path()).is_none() {
            tracing::error!(
                "Failed to remove stepinfo drv={} from jobs!",
                stepinfo.step.get_drv_path(),
            );
        }
        // active should be removed
        queue.scrube_jobs();
    }

    #[tracing::instrument(skip(self))]
    async fn kill_active_steps(&self) -> Vec<(nix_utils::StorePath, uuid::Uuid)> {
        tracing::info!("Kill all active steps");
        let active = {
            let scheduled = self.scheduled.read();
            scheduled.clone()
        };

        let mut cancelled_steps = vec![];
        for (drv_path, item) in &active {
            if item.step_info.get_cancelled() {
                continue;
            }

            let mut dependents = HashSet::new();
            let mut steps = HashSet::new();
            item.step_info
                .step
                .get_dependents(&mut dependents, &mut steps);
            if !dependents.is_empty() {
                continue;
            }

            {
                tracing::info!("Cancelling step drv={drv_path}");
                item.step_info.set_cancelled(true);

                if let Some(internal_build_id) =
                    item.machine.get_internal_build_id_for_drv(drv_path)
                {
                    if let Err(e) = item.machine.abort_build(internal_build_id).await {
                        tracing::error!(
                            "Failed to abort build drv_path={drv_path} build_id={internal_build_id} e={e}",
                        );
                        continue;
                    }
                } else {
                    tracing::warn!("No active build_id found for drv_path={drv_path}",);
                    continue;
                }

                cancelled_steps.push((drv_path.to_owned(), item.machine.id));
            }
        }
        cancelled_steps
    }

    #[tracing::instrument(skip(self))]
    fn get_stats_per_queue(&self) -> HashMap<System, BuildQueueStats> {
        self.inner
            .iter()
            .map(|(k, v)| (k.clone(), v.get_stats()))
            .collect()
    }

    fn get_jobs(&self) -> Vec<Arc<StepInfo>> {
        self.jobs.values().map(Clone::clone).collect()
    }

    fn get_scheduled(&self) -> Vec<Arc<StepInfo>> {
        let s = self.scheduled.read();
        s.iter().map(|(_, item)| item.step_info.clone()).collect()
    }

    pub fn sort_queues(&self, sort_fn: StepSortFn) {
        for q in self.inner.values() {
            q.sort_jobs(sort_fn);
        }
    }
}

pub struct JobConstraint {
    job: Arc<StepInfo>,
    system: System,
    queue_features: SmallVec<[String; 4]>,
}

impl JobConstraint {
    pub const fn new(
        job: Arc<StepInfo>,
        system: System,
        queue_features: SmallVec<[String; 4]>,
    ) -> Self {
        Self {
            job,
            system,
            queue_features,
        }
    }

    pub fn resolve(
        self,
        machines: &crate::state::Machines,
        free_fn: crate::config::MachineFreeFn,
    ) -> Option<(Arc<crate::state::Machine>, Arc<StepInfo>)> {
        let step_features = self.job.step.get_required_features();
        let merged_features = if self.queue_features.is_empty() {
            step_features
        } else {
            [step_features.as_slice(), self.queue_features.as_slice()].concat()
        };
        if let Some(machine) =
            machines.get_machine_for_system(&self.system, &merged_features, Some(free_fn))
        {
            Some((machine, self.job))
        } else {
            let drv = self.job.step.get_drv_path();
            tracing::debug!("No free machine found for system={} drv={drv}", self.system);
            None
        }
    }
}

#[derive(Clone)]
pub struct Queues {
    inner: Arc<tokio::sync::RwLock<InnerQueues>>,
}

impl Default for Queues {
    fn default() -> Self {
        Self::new()
    }
}

impl Queues {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(tokio::sync::RwLock::new(InnerQueues::new())),
        }
    }

    #[tracing::instrument(skip(self, jobs))]
    pub async fn insert_new_jobs<S: Into<String> + std::fmt::Debug>(
        &self,
        system: S,
        jobs: Vec<StepInfo>,
        now: &jiff::Timestamp,
        sort_fn: StepSortFn,
        metrics: &super::metrics::PromMetrics,
    ) {
        let sort_duration = self
            .inner
            .write()
            .await
            .insert_new_jobs(system, jobs, now, sort_fn);
        metrics.queue_sort_duration_ms_total.inc_by(sort_duration);
    }

    #[tracing::instrument(skip(self))]
    pub async fn remove_all_weak_pointer(&self) {
        let rq = self.inner.write().await;
        rq.remove_all_weak_pointer();
    }

    #[tracing::instrument(skip(self))]
    pub async fn ensure_queues_for_systems(&self, systems: &[System]) {
        let mut wq = self.inner.write().await;
        wq.ensure_queues_for_systems(systems);
    }

    pub(super) async fn process<F>(
        &self,
        processor: F,
        metrics: &super::metrics::PromMetrics,
    ) -> i64
    where
        F: AsyncFn(JobConstraint) -> anyhow::Result<crate::state::RealiseStepResult>,
    {
        let now = jiff::Timestamp::now();
        let mut nr_steps_waiting_all_queues = 0;
        let queues = self.clone_inner().await;
        for (system, queue) in queues {
            let mut nr_disabled = 0;
            let mut nr_waiting = 0;
            for job in queue.clone_inner() {
                let Some(job) = job.upgrade() else {
                    continue;
                };
                if job.get_already_scheduled() {
                    tracing::debug!(
                        "Can't schedule job because job is already scheduled system={system} drv={}",
                        job.step.get_drv_path()
                    );
                    continue;
                }
                if job.step.get_finished() {
                    tracing::debug!(
                        "Can't schedule job because job is already finished system={system} drv={}",
                        job.step.get_drv_path()
                    );
                    continue;
                }
                let after = job.step.get_after();
                if after > now {
                    nr_disabled += 1;
                    tracing::debug!(
                        "Can't schedule job because job is not yet ready system={system} drv={} after={after}",
                        job.step.get_drv_path(),
                    );
                    continue;
                }
                let constraint = JobConstraint::new(job.clone(), system.clone(), SmallVec::new());
                match processor(constraint).await {
                    Ok(crate::state::RealiseStepResult::Valid(m)) => {
                        let wait_seconds = now.duration_since(job.runnable_since).as_secs_f64();
                        metrics.observe_job_wait_time(wait_seconds, &system);

                        self.add_job_to_scheduled(&job, &queue, m).await;
                    }
                    Ok(crate::state::RealiseStepResult::None) => {
                        tracing::debug!(
                            "Waiting for job to schedule because no builder is ready system={system} drv={}",
                            job.step.get_drv_path(),
                        );
                        nr_waiting += 1;
                        nr_steps_waiting_all_queues += 1;
                    }
                    Ok(
                        crate::state::RealiseStepResult::MaybeCancelled
                        | crate::state::RealiseStepResult::CachedFailure,
                    ) => {
                        // If this is maybe cancelled (and the cancellation is correct) it is
                        // enough to remove it from jobs which will then reduce the ref count
                        // to 0 as it has no dependents.
                        // If its a cached failure we need to also remove it from jobs, we
                        // already wrote cached failure into the db, at this point in time
                        self.remove_job(&job, &queue).await;

                        metrics.queue_aborted_jobs_total.inc();
                    }
                    Err(e) => {
                        tracing::warn!(
                            "Failed to realise drv on valid machine, will be skipped: drv={} e={e}",
                            job.step.get_drv_path(),
                        );
                    }
                }
                queue.set_nr_runnable_waiting(nr_waiting);
                queue.set_nr_runnable_disabled(nr_disabled);
            }
        }
        nr_steps_waiting_all_queues
    }

    pub async fn clone_inner(&self) -> HashMap<System, Arc<BuildQueue>> {
        self.inner.read().await.clone_inner()
    }

    #[tracing::instrument(skip(self, step, queue))]
    pub async fn add_job_to_scheduled(
        &self,
        step: &Arc<StepInfo>,
        queue: &Arc<BuildQueue>,
        machine: Arc<super::Machine>,
    ) {
        let rq = self.inner.read().await;
        rq.add_job_to_scheduled(step, queue, machine);
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    pub async fn remove_job_from_scheduled(
        &self,
        drv: &nix_utils::StorePath,
    ) -> Option<ScheduledItem> {
        let rq = self.inner.read().await;
        rq.remove_job_from_scheduled(drv)
    }

    pub async fn remove_job_by_path(&self, drv: &nix_utils::StorePath) {
        let mut wq = self.inner.write().await;
        wq.remove_job_by_path(drv);
    }

    #[tracing::instrument(skip(self, stepinfo, queue))]
    pub async fn remove_job(&self, stepinfo: &Arc<StepInfo>, queue: &Arc<BuildQueue>) {
        let mut wq = self.inner.write().await;
        wq.remove_job(stepinfo, queue);
    }

    #[tracing::instrument(skip(self))]
    pub async fn kill_active_steps(&self) -> Vec<(nix_utils::StorePath, uuid::Uuid)> {
        let rq = self.inner.read().await;
        rq.kill_active_steps().await
    }

    #[tracing::instrument(skip(self))]
    pub async fn get_stats_per_queue(&self) -> HashMap<System, BuildQueueStats> {
        self.inner.read().await.get_stats_per_queue()
    }

    pub async fn get_jobs(&self) -> Vec<Arc<StepInfo>> {
        let rq = self.inner.read().await;
        rq.get_jobs()
    }

    pub async fn get_scheduled(&self) -> Vec<Arc<StepInfo>> {
        let rq = self.inner.read().await;
        rq.get_scheduled()
    }

    pub async fn sort_queues(&self, sort_fn: StepSortFn) {
        let rq = self.inner.read().await;
        rq.sort_queues(sort_fn);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::System;

    #[tokio::test]
    async fn test_ensure_queues_for_systems() {
        let queues = Queues::new();
        let systems = vec!["system1".to_string(), "system2".to_string()];

        // Ensure queues for systems
        queues.ensure_queues_for_systems(&systems).await;

        // Check that queues were created
        let inner = queues.inner.read().await;
        assert!(inner.inner.contains_key("system1"));
        assert!(inner.inner.contains_key("system2"));
        assert_eq!(inner.inner.len(), 2);
    }

    #[tokio::test]
    async fn test_ensure_queues_for_systems_empty() {
        let queues = Queues::new();
        let systems: Vec<System> = vec![];

        // Ensure queues for empty systems list
        queues.ensure_queues_for_systems(&systems).await;

        // Check that no queues were created
        let inner = queues.inner.read().await;
        assert_eq!(inner.inner.len(), 0);
    }

    #[tokio::test]
    async fn test_ensure_queues_for_systems_duplicate() {
        let queues = Queues::new();
        let systems1 = vec!["system1".to_string(), "system2".to_string()];
        let systems2 = vec!["system2".to_string(), "system3".to_string()];

        // Ensure queues for first set of systems
        queues.ensure_queues_for_systems(&systems1).await;

        // Ensure queues for second set of systems (with overlap)
        queues.ensure_queues_for_systems(&systems2).await;

        // Check that all queues were created but no duplicates
        let inner = queues.inner.read().await;
        assert!(inner.inner.contains_key("system1"));
        assert!(inner.inner.contains_key("system2"));
        assert!(inner.inner.contains_key("system3"));
        assert_eq!(inner.inner.len(), 3);
    }

    #[tokio::test]
    async fn test_insert_machine_creates_queues_integration() {
        // Test the integration concept - what happens when insert_machine is called
        let systems = vec!["x86_64-linux".to_string(), "aarch64-linux".to_string()];
        let queues = Queues::new();

        // Before: no queues
        let inner_before = queues.inner.read().await;
        assert_eq!(inner_before.inner.len(), 0);
        drop(inner_before);

        // Call ensure_queues_for_systems (what insert_machine does)
        queues.ensure_queues_for_systems(&systems).await;

        // After: queues should exist for all systems
        let inner_after = queues.inner.read().await;
        assert_eq!(inner_after.inner.len(), 2);
        assert!(inner_after.inner.contains_key("x86_64-linux"));
        assert!(inner_after.inner.contains_key("aarch64-linux"));
    }
}
