mod atomic;
mod build;
mod jobset;
mod machine;
mod metrics;
mod queue;
mod uploader;

pub use atomic::AtomicDateTime;
pub use build::{Build, BuildOutput, BuildResultState, RemoteBuild, Step};
pub use jobset::{Jobset, JobsetID};
pub use machine::{Machine, Message as MachineMessage, Pressure, Stats as MachineStats};
pub use queue::{BuildQueueStats, StepInfo};

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Instant;
use std::{sync::Arc, sync::Weak};

use ahash::{AHashMap, AHashSet};
use db::models::{BuildID, BuildStatus};
use futures::TryStreamExt as _;
use nix_utils::BaseStore as _;
use secrecy::ExposeSecret as _;

use crate::config::{App, Args};
use crate::state::build::get_mark_build_sccuess_data;
use crate::state::jobset::SCHEDULING_WINDOW;
use crate::utils::finish_build_step;
use machine::Machines;

pub type System = String;

enum CreateStepResult {
    None,
    Valid(Arc<Step>),
    PreviousFailure(Arc<Step>),
}

enum RealiseStepResult {
    None,
    Valid(Arc<Machine>),
    MaybeCancelled,
    CachedFailure,
}

pub struct State {
    pub store: nix_utils::LocalStore,
    pub remote_stores: parking_lot::RwLock<Vec<nix_utils::RemoteStore>>,
    pub config: App,
    pub args: Args,
    pub db: db::Database,

    pub machines: Machines,

    pub log_dir: std::path::PathBuf,

    // hardcoded values fromold queue runner
    // pub maxParallelCopyClosure: u32 = 4;
    // pub maxUnsupportedTime: u32 = 0;
    pub builds: parking_lot::RwLock<AHashMap<BuildID, Arc<Build>>>,
    // Projectname, Jobsetname
    pub jobsets: parking_lot::RwLock<AHashMap<(String, String), Arc<Jobset>>>,
    pub steps: parking_lot::RwLock<AHashMap<nix_utils::StorePath, Weak<Step>>>,
    pub queues: tokio::sync::RwLock<queue::Queues>,

    pub started_at: chrono::DateTime<chrono::Utc>,

    pub metrics: metrics::PromMetrics,
    pub notify_dispatch: tokio::sync::Notify,
    pub uploader: uploader::Uploader,
}

impl State {
    pub async fn new(
        reload_handle: tracing_subscriber::reload::Handle<
            tracing_subscriber::EnvFilter,
            tracing_subscriber::Registry,
        >,
    ) -> anyhow::Result<Arc<Self>> {
        let store = nix_utils::LocalStore::init();
        nix_utils::set_verbosity(1);
        let args = Args::new();
        if args.status {
            let _ = reload_handle
                .modify(|filter| *filter = tracing_subscriber::filter::EnvFilter::new("error"));
        }

        let config = App::init(&args.config_path)?;
        let log_dir = config.get_hydra_log_dir();
        let db = db::Database::new(
            config.get_db_url().expose_secret(),
            config.get_max_db_connections(),
        )
        .await?;

        let _ = tokio::fs::create_dir_all(&log_dir).await;
        Ok(Arc::new(Self {
            store,
            remote_stores: parking_lot::RwLock::new(
                config
                    .get_remote_store_addrs()
                    .iter()
                    .map(|v| nix_utils::RemoteStore::init(v))
                    .collect(),
            ),
            config,
            args,
            db,
            machines: Machines::new(),
            log_dir,
            builds: parking_lot::RwLock::new(AHashMap::new()),
            jobsets: parking_lot::RwLock::new(AHashMap::new()),
            steps: parking_lot::RwLock::new(AHashMap::new()),
            queues: tokio::sync::RwLock::new(queue::Queues::new()),
            started_at: chrono::Utc::now(),
            metrics: metrics::PromMetrics::new()?,
            notify_dispatch: tokio::sync::Notify::new(),
            uploader: uploader::Uploader::new(),
        }))
    }

    pub fn reload_config_callback(
        &self,
        new_config: &crate::config::PreparedApp,
    ) -> anyhow::Result<()> {
        // IF this gets more complex we need a way to trap the state and revert.
        // right now it doesnt matter because only reconfigure_pool can fail and this is the first
        // thing we do.

        let curr_db_url = self.config.get_db_url();
        let curr_sort_fn = self.config.get_sort_fn();
        let curr_remote_stores = self.config.get_remote_store_addrs();
        if curr_db_url.expose_secret() != new_config.db_url.expose_secret() {
            self.db
                .reconfigure_pool(new_config.db_url.expose_secret())?;
        }
        if curr_sort_fn != new_config.machine_sort_fn {
            self.machines.sort(new_config.machine_sort_fn);
        }
        if curr_remote_stores != new_config.remote_store_addr {
            let mut remote_stores = self.remote_stores.write();
            *remote_stores = new_config
                .remote_store_addr
                .iter()
                .map(|v| nix_utils::RemoteStore::init(v))
                .collect();
        }
        Ok(())
    }

    pub fn get_nr_builds_unfinished(&self) -> usize {
        self.builds.read().len()
    }

    pub fn get_nr_steps_unfinished(&self) -> usize {
        let mut steps = self.steps.write();
        steps.retain(|_, s| s.upgrade().is_some());
        steps.len()
    }

    pub fn get_nr_runnable(&self) -> usize {
        let mut steps = self.steps.write();
        steps.retain(|_, s| s.upgrade().is_some());
        steps
            .iter()
            .filter_map(|(_, s)| s.upgrade().map(|v| v.get_runnable()))
            .filter(|v| *v)
            .count()
    }

    #[tracing::instrument(skip(self, machine))]
    pub async fn insert_machine(&self, machine: Machine) -> uuid::Uuid {
        let machine_id = self
            .machines
            .insert_machine(machine, self.config.get_sort_fn());
        self.trigger_dispatch();
        machine_id
    }

    #[tracing::instrument(skip(self))]
    pub async fn remove_machine(&self, machine_id: uuid::Uuid) {
        if let Some(m) = self.machines.remove_machine(machine_id) {
            let jobs = {
                let jobs = m.jobs.read();
                jobs.clone()
            };
            for job in &jobs {
                if let Err(e) = self
                    .fail_step(
                        Some(machine_id),
                        &job.path,
                        // we fail this with preparing because we kinda want to restart all jobs if
                        // a machine is removed
                        BuildResultState::PreparingFailure,
                        std::time::Duration::from_secs(0),
                        std::time::Duration::from_secs(0),
                    )
                    .await
                {
                    log::error!(
                        "Failed to fail step machine_id={machine_id} drv={} e={e}",
                        job.path
                    );
                }
            }
        }
    }

    pub async fn remove_all_machines(&self) {
        for m in self.machines.get_all_machines() {
            self.remove_machine(m.id).await;
        }
    }

    pub async fn clear_busy(&self) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;
        db.clear_busy(0).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, step_info, system), err)]
    async fn realise_drv_on_valid_machine(
        &self,
        step_info: Arc<StepInfo>,
        system: &System,
    ) -> anyhow::Result<RealiseStepResult> {
        let drv = step_info.step.get_drv_path();
        let free_fn = self.config.get_free_fn();

        let Some(machine) = self.machines.get_machine_for_system(
            system,
            &step_info.step.get_required_features(),
            free_fn,
        ) else {
            log::debug!("No free machine found for system={system} drv={drv}");
            return Ok(RealiseStepResult::None);
        };

        let mut build_options = nix_utils::BuildOptions::new(None);
        let build_id = {
            let mut dependents = AHashSet::new();
            let mut steps = AHashSet::new();
            step_info.step.get_dependents(&mut dependents, &mut steps);

            if dependents.is_empty() {
                // Apparently all builds that depend on this derivation are gone (e.g. cancelled). So
                // don't bother. This is very unlikely to happen, because normally Steps are only kept
                // alive by being reachable from a Build. However, it's possible that a new Build just
                // created a reference to this step. So to handle that possibility, we retry this step
                // (putting it back in the runnable queue). If there are really no strong pointers to
                // the step, it will be deleted.
                log::info!("maybe cancelling build step {drv}");
                return Ok(RealiseStepResult::MaybeCancelled);
            }

            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or(dependents.iter().next())
            else {
                // this should never happen, as we checked is_empty above and fallback is just any build
                return Ok(RealiseStepResult::MaybeCancelled);
            };

            // We want the biggest timeout otherwise we could build a step like llvm with a timeout
            // of 180 because a nixostest with a timeout got scheduled and needs this step
            let biggest_max_silent_time = dependents.iter().map(|x| x.max_silent_time).max();
            let biggest_build_timeout = dependents.iter().map(|x| x.timeout).max();

            build_options
                .set_max_silent_time(biggest_max_silent_time.unwrap_or(build.max_silent_time));
            build_options.set_build_timeout(biggest_build_timeout.unwrap_or(build.timeout));
            build.id
        };

        let mut job = machine::Job::new(
            build_id,
            drv.to_owned(),
            step_info.resolved_drv_path.clone(),
        );
        job.result.start_time = Some(chrono::Utc::now());
        if self.check_cached_failure(step_info.step.clone()).await {
            job.result.step_status = BuildStatus::CachedFailure;
            self.inner_fail_job(drv, None, job, step_info.step.clone())
                .await?;
            return Ok(RealiseStepResult::CachedFailure);
        }

        self.construct_log_file_path(drv)
            .await?
            .to_str()
            .ok_or(anyhow::anyhow!("failed to construct log path string."))?
            .clone_into(&mut job.result.log_file);
        let step_nr = {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;

            let step_nr = tx
                .create_build_step(
                    job.result.start_time.map(|s| s.timestamp()),
                    build_id,
                    &step_info.step.get_drv_path().get_full_path(),
                    step_info.step.get_system().as_deref(),
                    machine.hostname.clone(),
                    BuildStatus::Busy,
                    None,
                    None,
                    step_info
                        .step
                        .get_outputs()
                        .unwrap_or_default()
                        .into_iter()
                        .map(|o| (o.name, o.path.map(|s| s.get_full_path())))
                        .collect(),
                )
                .await?;
            tx.commit().await?;
            step_nr
        };
        job.step_nr = step_nr;

        log::info!(
            "Submitting build drv={drv} on machine={} hostname={} build_id={build_id} step_nr={step_nr}",
            machine.id,
            machine.hostname
        );
        self.db
            .get()
            .await?
            .update_build_step(db::models::UpdateBuildStep {
                build_id,
                step_nr,
                status: db::models::StepStatus::Connecting,
            })
            .await?;
        machine.build_drv(job, &build_options).await?;
        self.metrics.nr_steps_started.add(1);
        self.metrics.nr_steps_building.add(1);
        Ok(RealiseStepResult::Valid(machine))
    }

    #[tracing::instrument(skip(self), fields(%drv), err)]
    async fn construct_log_file_path(
        &self,
        drv: &nix_utils::StorePath,
    ) -> anyhow::Result<std::path::PathBuf> {
        let mut log_file = self.log_dir.clone();
        let (dir, file) = drv.base_name().split_at(2);
        log_file.push(format!("{dir}/"));
        let _ = tokio::fs::create_dir_all(&log_file).await; // create dir
        log_file.push(file);
        Ok(log_file)
    }

    #[tracing::instrument(skip(self), fields(%drv), err)]
    pub async fn new_log_file(
        &self,
        drv: &nix_utils::StorePath,
    ) -> anyhow::Result<tokio::fs::File> {
        let log_file = self.construct_log_file_path(drv).await?;
        log::debug!("opening {log_file:?}");

        Ok(tokio::fs::File::options()
            .create(true)
            .truncate(true)
            .write(true)
            .read(false)
            .mode(0o666)
            .open(log_file)
            .await?)
    }

    #[tracing::instrument(skip(self, new_ids, new_builds_by_id, new_builds_by_path))]
    async fn process_new_builds(
        &self,
        new_ids: Vec<BuildID>,
        new_builds_by_id: Arc<parking_lot::RwLock<AHashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: AHashMap<nix_utils::StorePath, AHashSet<BuildID>>,
    ) {
        let finished_drvs = Arc::new(parking_lot::RwLock::new(
            AHashSet::<nix_utils::StorePath>::new(),
        ));

        let starttime = chrono::Utc::now();
        for id in new_ids {
            let build = {
                let new_builds_by_id = new_builds_by_id.read();
                let Some(build) = new_builds_by_id.get(&id).cloned() else {
                    continue;
                };
                build
            };

            let new_runnable = Arc::new(parking_lot::RwLock::new(AHashSet::<Arc<Step>>::new()));
            let nr_added: Arc<AtomicI64> = Arc::new(0.into());
            let now = Instant::now();

            self.create_build(
                build,
                nr_added.clone(),
                new_builds_by_id.clone(),
                &new_builds_by_path,
                finished_drvs.clone(),
                new_runnable.clone(),
            )
            .await;

            // we should never run into this issue
            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .build_read_time_ms
                .add(now.elapsed().as_millis() as i64);

            {
                let new_runnable = new_runnable.read();
                log::info!(
                    "got {} new runnable steps from {} new builds",
                    new_runnable.len(),
                    nr_added.load(Ordering::Relaxed)
                );
                for r in new_runnable.iter() {
                    r.make_runnable();
                }
            }

            self.metrics
                .nr_builds_read
                .add(nr_added.load(Ordering::Relaxed));
            let stop_queue_run_after = self.config.get_stop_queue_run_after();

            if let Some(stop_queue_run_after) = stop_queue_run_after {
                if chrono::Utc::now() > (starttime + stop_queue_run_after) {
                    self.metrics.queue_checks_early_exits.inc();
                    break;
                }
            }
        }

        {
            // This is here to ensure that we dont have any deps to finished steps
            // This can happen because step creation is async and is_new can return a step that is
            // still undecided if its finished or not.
            let steps = self.steps.read();
            for (_, s) in steps.iter() {
                let Some(s) = s.upgrade() else {
                    continue;
                };
                if s.get_finished() && !s.get_previous_failure() {
                    s.make_rdeps_runnable();
                }
                // TODO: if previous failure we should propably also remove from deps
            }
        }

        // we can just always trigger dispatch as we might have a free machine and its cheap
        self.metrics.queue_checks_finished.inc();
        self.trigger_dispatch();
    }

    #[tracing::instrument(skip(self), err)]
    async fn process_queue_change(&self) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;
        let curr_ids = db
            .get_not_finished_builds_fast()
            .await?
            .into_iter()
            .map(|b| (b.id, b.globalpriority))
            .collect::<AHashMap<_, _>>();

        {
            let mut builds = self.builds.write();
            builds.retain(|k, _| curr_ids.contains_key(k));
            for (id, build) in builds.iter() {
                let Some(new_priority) = curr_ids.get(id) else {
                    // we should never get into this case because of the retain above
                    continue;
                };

                if build.global_priority.load(Ordering::Relaxed) < *new_priority {
                    log::info!("priority of build {id} increased");
                    build
                        .global_priority
                        .store(*new_priority, Ordering::Relaxed);
                    build.propagate_priorities();
                }
            }
        }

        let queues = self.queues.read().await;
        let cancelled_steps = queues.kill_active_steps().await;
        for (drv_path, machine_id) in cancelled_steps {
            if let Err(e) = self
                .fail_step(
                    Some(machine_id),
                    &drv_path,
                    BuildResultState::Cancelled,
                    std::time::Duration::from_secs(0),
                    std::time::Duration::from_secs(0),
                )
                .await
            {
                log::error!("Failed to abort step machine_id={machine_id} drv={drv_path} e={e}",);
            }
        }
        Ok(())
    }

    #[tracing::instrument(skip(self), fields(%drv_path))]
    pub async fn queue_one_build(
        &self,
        jobset_id: i32,
        drv_path: &nix_utils::StorePath,
    ) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;
        let drv = nix_utils::query_drv(drv_path)
            .await?
            .ok_or(anyhow::anyhow!("drv not found"))?;
        db.insert_debug_build(jobset_id, &drv_path.get_full_path(), &drv.system)
            .await?;

        let mut tx = db.begin_transaction().await?;
        tx.notify_builds_added().await?;
        tx.commit().await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_queued_builds(&self) -> anyhow::Result<()> {
        self.metrics.queue_checks_started.inc();

        let mut new_ids = Vec::<BuildID>::new();
        let mut new_builds_by_id = AHashMap::<BuildID, Arc<Build>>::new();
        let mut new_builds_by_path = AHashMap::<nix_utils::StorePath, AHashSet<BuildID>>::default();

        {
            let mut conn = self.db.get().await?;
            for b in conn.get_not_finished_builds().await? {
                let jobset = self
                    .create_jobset(&mut conn, b.jobset_id, &b.project, &b.jobset)
                    .await?;
                let build = Build::new(b, jobset)?;
                new_ids.push(build.id);
                new_builds_by_id.insert(build.id, build.clone());
                new_builds_by_path
                    .entry(build.drv_path.clone())
                    .or_insert_with(AHashSet::new)
                    .insert(build.id);
            }
        }
        log::debug!("new_ids: {new_ids:?}");
        log::debug!("new_builds_by_id: {new_builds_by_id:?}");
        log::debug!("new_builds_by_path: {new_builds_by_path:?}");

        let new_builds_by_id = Arc::new(parking_lot::RwLock::new(new_builds_by_id));
        self.process_new_builds(new_ids, new_builds_by_id, new_builds_by_path)
            .await;
        Ok(())
    }

    #[tracing::instrument(skip(self))]
    pub fn start_queue_monitor_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                if let Err(e) = self.queue_monitor_loop().await {
                    log::error!("Failed to spawn queue monitor loop. e={e}");
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self), err)]
    async fn queue_monitor_loop(&self) -> anyhow::Result<()> {
        let mut listener = self
            .db
            .listener(vec![
                "builds_added",
                "builds_restarted",
                "builds_cancelled",
                "builds_deleted",
                "builds_bumped",
                "jobset_shares_changed",
            ])
            .await?;

        loop {
            let before_work = Instant::now();
            self.store.clear_path_info_cache();
            if let Err(e) = self.get_queued_builds().await {
                log::error!("get_queue_builds failed inside queue monitor loop: {e}");
                continue;
            }

            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .queue_monitor_time_spent_running
                .inc_by(before_work.elapsed().as_micros() as u64);

            let before_sleep = Instant::now();
            let queue_trigger_timer = self.config.get_queue_trigger_timer();
            let notification = if let Some(timer) = queue_trigger_timer {
                tokio::select! {
                    () = tokio::time::sleep(timer) => {"timer_reached".into()},
                    v = listener.try_next() => match v {
                        Ok(Some(v)) => v.channel().to_owned(),
                        Ok(None) => continue,
                        Err(e) => {
                            log::warn!("PgListener failed with e={e}");
                            continue;
                        }
                    },
                }
            } else {
                match listener.try_next().await {
                    Ok(Some(v)) => v.channel().to_owned(),
                    Ok(None) => continue,
                    Err(e) => {
                        log::warn!("PgListener failed with e={e}");
                        continue;
                    }
                }
            };
            self.metrics.nr_queue_wakeups.add(1);
            log::trace!("New notification from PgListener. notification={notification:?}");

            match notification.as_ref() {
                "builds_added" => log::debug!("got notification: new builds added to the queue"),
                "builds_restarted" => log::debug!("got notification: builds restarted"),
                "builds_cancelled" | "builds_deleted" | "builds_bumped" => {
                    log::debug!("got notification: builds cancelled or bumped");
                    if let Err(e) = self.process_queue_change().await {
                        log::error!("Failed to process queue change. e={e}");
                    }
                }
                "jobset_shares_changed" => {
                    log::debug!("got notification: jobset shares changed");
                    if let Err(e) = self.handle_jobset_change().await {
                        log::error!("Failed to handle jobset change. e={e}");
                    }
                }
                _ => (),
            }

            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .queue_monitor_time_spent_waiting
                .inc_by(before_sleep.elapsed().as_micros() as u64);
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn start_dispatch_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                loop {
                    let before_sleep = Instant::now();
                    let dispatch_trigger_timer = self.config.get_dispatch_trigger_timer();
                    if let Some(timer) = dispatch_trigger_timer {
                        tokio::select! {
                            () = self.notify_dispatch.notified() => {},
                            () = tokio::time::sleep(timer) => {},
                        };
                    } else {
                        self.notify_dispatch.notified().await;
                    }
                    log::info!("starting dispatch");

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_waiting
                        .inc_by(before_sleep.elapsed().as_micros() as u64);

                    self.metrics.nr_dispatcher_wakeups.add(1);
                    let before_work = Instant::now();
                    self.do_dispatch_once().await;

                    let elapsed = before_work.elapsed();

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_running
                        .inc_by(elapsed.as_micros() as u64);

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatch_time_ms
                        .add(elapsed.as_millis() as i64);
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self), err)]
    async fn dump_status_loop(self: Arc<State>) -> anyhow::Result<()> {
        let mut listener = self.db.listener(vec!["dump_status"]).await?;

        let state = self.clone();
        loop {
            let _ = match listener.try_next().await {
                Ok(Some(v)) => v,
                Ok(None) => continue,
                Err(e) => {
                    log::warn!("PgListener failed with e={e}");
                    continue;
                }
            };

            let state = state.clone();
            let queue_stats = crate::io::QueueRunnerStats::new(state.clone()).await;
            let sort_fn = state.config.get_sort_fn();
            let free_fn = state.config.get_free_fn();
            let machines = state
                .machines
                .get_all_machines()
                .into_iter()
                .map(|m| {
                    (
                        m.hostname.clone(),
                        crate::io::Machine::from_state(&m, sort_fn, free_fn),
                    )
                })
                .collect();
            let jobsets = {
                let jobsets = state.jobsets.read();
                jobsets
                    .values()
                    .map(|v| (v.full_name(), v.clone().into()))
                    .collect()
            };
            let remote_stores = {
                let stores = state.remote_stores.read();
                stores.clone()
            };
            let dump_status = crate::io::DumpResponse::new(
                queue_stats,
                machines,
                jobsets,
                &state.store,
                &remote_stores,
            );
            {
                let Ok(mut db) = self.db.get().await else {
                    continue;
                };
                let Ok(mut tx) = db.begin_transaction().await else {
                    continue;
                };
                let dump_status = match serde_json::to_value(dump_status) {
                    Ok(v) => v,
                    Err(e) => {
                        log::error!("Failed to update status in database: {e}");
                        continue;
                    }
                };
                if let Err(e) = tx.upsert_status(&dump_status).await {
                    log::error!("Failed to update status in database: {e}");
                    continue;
                }
                if let Err(e) = tx.notify_status_dumped().await {
                    log::error!("Failed to update status in database: {e}");
                    continue;
                }
                if let Err(e) = tx.commit().await {
                    log::error!("Failed to update status in database: {e}");
                }
            }
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn start_dump_status_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                if let Err(e) = self.dump_status_loop().await {
                    log::error!("Failed to spawn queue monitor loop. e={e}");
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self))]
    pub fn start_uploader_queue(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                loop {
                    let local_store = self.store.clone();
                    let remote_stores = {
                        let r = self.remote_stores.read();
                        r.clone()
                    };
                    let limit = self.config.get_concurrent_upload_limit();
                    if limit < 2 {
                        self.uploader.upload_once(local_store, remote_stores).await;
                    } else {
                        self.uploader
                            .upload_many(local_store, remote_stores, limit)
                            .await;
                    }
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self))]
    pub async fn get_status_from_main_process(self: Arc<Self>) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;

        let mut listener = self.db.listener(vec!["status_dumped"]).await?;
        {
            let mut tx = db.begin_transaction().await?;
            tx.notify_dump_status().await?;
            tx.commit().await?;
        }

        let _ = match listener.try_next().await {
            Ok(Some(v)) => v,
            Ok(None) => return Ok(()),
            Err(e) => {
                log::warn!("PgListener failed with e={e}");
                return Ok(());
            }
        };
        if let Some(status) = db.get_status().await? {
            println!("{}", serde_json::to_string_pretty(&status)?);
        }

        Ok(())
    }

    #[tracing::instrument(skip(self))]
    pub fn trigger_dispatch(&self) {
        self.notify_dispatch.notify_one();
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self))]
    async fn do_dispatch_once(&self) {
        // Prune old historical build step info from the jobsets.
        {
            let jobsets = self.jobsets.read();
            for ((project_name, jobset_name), jobset) in jobsets.iter() {
                let s1 = jobset.share_used();
                jobset.prune_steps();
                let s2 = jobset.share_used();
                if (s1 - s2).abs() > f64::EPSILON {
                    log::debug!(
                        "pruned scheduling window of '{project_name}:{jobset_name}' from {s1} to {s2}"
                    );
                }
            }
        }

        let mut new_runnable = Vec::new();
        {
            let mut steps = self.steps.write();
            steps.retain(|_, r| {
                let Some(step) = r.upgrade() else {
                    return false;
                };
                if step.get_runnable() {
                    new_runnable.push(step.clone());
                }
                true
            });
        }

        let now = chrono::Utc::now();
        let mut new_queues = AHashMap::<System, Vec<StepInfo>>::default();
        for r in new_runnable {
            let Some(system) = r.get_system() else {
                continue;
            };
            if r.atomic_state.tries.load(Ordering::Relaxed) > 0 {
                continue;
            }
            let step_info = StepInfo::new(&self.store, r.clone());

            new_queues
                .entry(system)
                .or_insert_with(Vec::new)
                .push(step_info);
        }

        {
            let mut queues = self.queues.write().await;
            for (system, jobs) in new_queues {
                queues.insert_new_jobs(system, jobs, &now);
            }
            queues.remove_all_weak_pointer();
        }

        {
            let mut nr_steps_waiting_all_queues = 0;
            let inner_queues = {
                // We clone the inner queues here to unlock it again fast for other jobs
                let queues = self.queues.read().await;
                queues.clone_inner()
            };
            let sort_fn = self.config.get_sort_fn();
            for (system, queue) in inner_queues {
                let mut nr_disabled = 0;
                let mut nr_waiting = 0;
                for job in queue.clone_inner() {
                    let Some(job) = job.upgrade() else {
                        continue;
                    };
                    if job.get_already_scheduled() {
                        log::debug!(
                            "Can't schedule job because job is already scheduled system={system} drv={}",
                            job.step.get_drv_path()
                        );
                        continue;
                    }
                    if job.step.get_finished() {
                        log::debug!(
                            "Can't schedule job because job is already finished system={system} drv={}",
                            job.step.get_drv_path()
                        );
                        continue;
                    }
                    {
                        let after = job.step.get_after();
                        if after > now {
                            nr_disabled += 1;
                            log::debug!(
                                "Can't schedule job because job is not yet ready system={system} drv={} after={after}",
                                job.step.get_drv_path(),
                            );
                            continue;
                        }
                    }

                    match self
                        .realise_drv_on_valid_machine(job.clone(), &system)
                        .await
                    {
                        Ok(RealiseStepResult::Valid(m)) => {
                            let queues = self.queues.read().await;
                            queues.add_job_to_scheduled(&job, &queue, m);
                            // if we sort after each successful schedule we basically get a least
                            // current builds as tie breaker, if we have the same score.
                            self.machines.sort(sort_fn);
                        }
                        Ok(RealiseStepResult::None) => {
                            log::debug!(
                                "Waiting for job to schedule because no builder is ready system={system} drv={}",
                                job.step.get_drv_path(),
                            );
                            nr_waiting += 1;
                            nr_steps_waiting_all_queues += 1;
                        }
                        Ok(
                            RealiseStepResult::MaybeCancelled | RealiseStepResult::CachedFailure,
                        ) => {
                            // If this is maybe cancelled (and the cancellation is correct) it is
                            // enough to remove it from jobs which will then reduce the ref count
                            // to 0 as it has no dependents.
                            // If its a cached failure we need to also remove it from jobs, we
                            // already wrote cached failure into the db, at this point in time
                            let mut queues = self.queues.write().await;
                            queues.remove_job(&job, &queue);
                        }
                        Err(e) => {
                            log::warn!(
                                "Failed to realise drv on valid machine, will be skipped: drv={} e={e}",
                                job.step.get_drv_path(),
                            );
                        }
                    }
                    queue.set_nr_runnable_waiting(nr_waiting);
                    queue.set_nr_runnable_disabled(nr_disabled);
                }
            }
            self.metrics
                .nr_steps_waiting
                .set(nr_steps_waiting_all_queues);
        }

        self.abort_unsupported().await;
    }

    #[tracing::instrument(skip(self, machine_id, step_status), fields(%drv_path), err)]
    pub async fn update_build_step(
        &self,
        machine_id: Option<uuid::Uuid>,
        drv_path: &nix_utils::StorePath,
        step_status: db::models::StepStatus,
    ) -> anyhow::Result<()> {
        let build_id_and_step_nr = if let Some(machine_id) = machine_id {
            if let Some(m) = self.machines.get_machine_by_id(machine_id) {
                log::debug!("get job from machine: drv_path={drv_path} m={}", m.id);
                m.get_build_id_and_step_nr(drv_path)
            } else {
                None
            }
        } else {
            None
        };

        let Some((build_id, step_nr)) = build_id_and_step_nr else {
            log::warn!(
                "Failed to find job with build_id and step_nr for machine_id={machine_id:?} drv_path={drv_path}."
            );
            return Ok(());
        };
        self.db
            .get()
            .await?
            .update_build_step(db::models::UpdateBuildStep {
                build_id,
                step_nr,
                status: step_status,
            })
            .await?;
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self, output), fields(%drv_path), err)]
    pub async fn succeed_step(
        &self,
        machine_id: Option<uuid::Uuid>,
        drv_path: &nix_utils::StorePath,
        output: BuildOutput,
    ) -> anyhow::Result<()> {
        log::info!("marking job as done: drv_path={drv_path}");
        let (step_info, queue, machine) = {
            let queues = self.queues.read().await;
            queues
                .remove_job_from_scheduled(drv_path)
                .ok_or(anyhow::anyhow!("Step is missing in queues.scheduled"))?
        };

        step_info.step.set_finished(true);
        self.metrics.nr_steps_done.add(1);
        self.metrics.nr_steps_building.sub(1);

        log::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            machine.id
        );
        let mut job = machine.remove_job(drv_path).ok_or(anyhow::anyhow!(
            "Job is missing in machine.jobs m={}",
            machine
        ))?;

        {
            let mut queues = self.queues.write().await;
            queues.remove_job(&step_info, &queue);
        }

        job.result.step_status = BuildStatus::Success;
        job.result.stop_time = Some(chrono::Utc::now());
        {
            let total_step_time = job.result.get_total_step_time_ms();
            machine
                .stats
                .add_to_total_step_time_ms(u128::from(total_step_time));
            machine
                .stats
                .add_to_total_step_import_time_ms(output.import_elapsed.as_millis());
            machine
                .stats
                .add_to_total_step_build_time_ms(output.build_elapsed.as_millis());
            machine.stats.reset_consecutive_failures();
            self.metrics
                .add_to_total_step_time_ms(u128::from(total_step_time));
            self.metrics
                .add_to_total_step_import_time_ms(output.import_elapsed.as_millis());
            self.metrics
                .add_to_total_step_build_time_ms(output.build_elapsed.as_millis());
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            finish_build_step(
                &mut tx,
                job.build_id,
                job.step_nr,
                &job.result,
                Some(machine.hostname.clone()),
            )
            .await?;
            tx.commit().await?;
        }

        // TODO: can retry: builder.cc:260

        for (_, path) in &output.outputs {
            self.add_root(path);
        }

        let has_stores = {
            let r = self.remote_stores.read();
            !r.is_empty()
        };
        if has_stores {
            let outputs = output
                .outputs
                .values()
                .map(Clone::clone)
                .collect::<Vec<_>>();

            let _ = self.uploader.schedule_upload(
                outputs,
                format!("log/{}", job.path.base_name()),
                // TODO: handle compression
                job.result.log_file,
            );
        }

        let mut direct = Vec::new();
        {
            let state = step_info.step.state.read();
            for b in &state.builds {
                let Some(b) = b.upgrade() else {
                    continue;
                };
                if !b.get_finished_in_db() {
                    direct.push(b);
                }
            }

            if direct.is_empty() {
                let mut steps = self.steps.write();
                steps.retain(|s, _| s != step_info.step.get_drv_path());
            }
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            for b in &direct {
                let is_cached = job.build_id != b.id || job.result.is_cached;
                tx.mark_succeeded_build(
                    get_mark_build_sccuess_data(b, &output),
                    is_cached,
                    i32::try_from(
                        job.result
                            .start_time
                            .map(|s| s.timestamp())
                            .unwrap_or_default(),
                    )?, // TODO
                    i32::try_from(
                        job.result
                            .stop_time
                            .map(|s| s.timestamp())
                            .unwrap_or_default(),
                    )?, // TODO
                )
                .await?;
                self.metrics.nr_builds_done.add(1);
            }

            tx.commit().await?;
        }

        {
            // Remove the direct dependencies from 'builds'. This will cause them to be
            // destroyed.
            let mut current_builds = self.builds.write();
            for b in &direct {
                b.set_finished_in_db(true);
                current_builds.remove(&b.id);
            }
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            for b in direct {
                tx.notify_build_finished(b.id, &[]).await?;
            }

            tx.commit().await?;
        }

        step_info.step.make_rdeps_runnable();

        // always trigger dispatch, as we now might have a free machine again
        self.trigger_dispatch();

        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self), fields(%drv_path), err)]
    pub async fn fail_step(
        &self,
        machine_id: Option<uuid::Uuid>,
        drv_path: &nix_utils::StorePath,
        state: BuildResultState,
        import_elapsed: std::time::Duration,
        build_elapsed: std::time::Duration,
    ) -> anyhow::Result<()> {
        log::info!("removing job from running in system queue: drv_path={drv_path}");
        let (step_info, queue, machine) = {
            let queues = self.queues.read().await;
            queues
                .remove_job_from_scheduled(drv_path)
                .ok_or(anyhow::anyhow!("Step is missing in queues.scheduled"))?
        };

        step_info.step.set_finished(false);
        self.metrics.nr_steps_done.add(1);
        self.metrics.nr_steps_building.sub(1);

        log::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            machine.id
        );
        let mut job = machine.remove_job(drv_path).ok_or(anyhow::anyhow!(
            "Job is missing in machine.jobs m={}",
            machine
        ))?;

        job.result.step_status = BuildStatus::Failed;
        // this can override step_status to something more specific
        job.result.update_with_result_state(&state);

        // TODO: max failure count
        let (max_retries, retry_interval, retry_backoff) = self.config.get_retry();

        if job.result.can_retry {
            step_info
                .step
                .atomic_state
                .tries
                .fetch_add(1, Ordering::Relaxed);
            let tries = step_info.step.atomic_state.tries.load(Ordering::Relaxed);
            if tries < max_retries {
                // retry step
                // TODO: update metrics:
                // - build_step_time_ms,
                // - total_step_time_ms,
                // - maschine.build_step_time_ms,
                // - maschine.total_step_time_ms,
                // - maschine.last_failure
                self.metrics.nr_retries.add(1);
                #[allow(clippy::cast_precision_loss)]
                #[allow(clippy::cast_possible_truncation)]
                let delta = (retry_interval * retry_backoff.powf((tries - 1) as f32)) as i64;
                log::info!("will retry '{drv_path}' after {delta}s");
                step_info
                    .step
                    .set_after(chrono::Utc::now() + chrono::Duration::seconds(delta));
                if i64::from(tries) > self.metrics.max_nr_retries.get() {
                    self.metrics.max_nr_retries.set(i64::from(tries));
                }

                step_info.set_already_scheduled(false);

                {
                    let mut db = self.db.get().await?;
                    let mut tx = db.begin_transaction().await?;
                    finish_build_step(
                        &mut tx,
                        job.build_id,
                        job.step_nr,
                        &job.result,
                        Some(machine.hostname.clone()),
                    )
                    .await?;
                    tx.commit().await?;
                }
                self.trigger_dispatch();
                return Ok(());
            }
        }

        // remove job from queues, aka actually fail the job
        {
            let mut queues = self.queues.write().await;
            queues.remove_job(&step_info, &queue);
        }

        machine
            .stats
            .add_to_total_step_build_time_ms(build_elapsed.as_millis());
        machine
            .stats
            .add_to_total_step_import_time_ms(import_elapsed.as_millis());
        self.metrics
            .add_to_total_step_build_time_ms(build_elapsed.as_millis());
        self.metrics
            .add_to_total_step_import_time_ms(import_elapsed.as_millis());

        self.inner_fail_job(drv_path, Some(machine), job, step_info.step.clone())
            .await
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self, machine, job, step), fields(%drv_path), err)]
    async fn inner_fail_job(
        &self,
        drv_path: &nix_utils::StorePath,
        machine: Option<Arc<Machine>>,
        mut job: machine::Job,
        step: Arc<Step>,
    ) -> anyhow::Result<()> {
        job.result.stop_time = Some(chrono::Utc::now());
        {
            let total_step_time = job.result.get_total_step_time_ms();
            self.metrics
                .add_to_total_step_time_ms(u128::from(total_step_time));
            if let Some(machine) = &machine {
                machine
                    .stats
                    .add_to_total_step_time_ms(u128::from(total_step_time));
                machine.stats.store_last_failure_now();
            }
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            finish_build_step(
                &mut tx,
                job.build_id,
                job.step_nr,
                &job.result,
                machine.as_ref().map(|m| m.hostname.clone()),
            )
            .await?;
            tx.commit().await?;
        }

        // TODO: builder:415
        let mut dependent_ids = Vec::new();
        loop {
            let indirect = self.get_all_indirect_builds(&step);
            // TODO: stepFinished ?
            if indirect.is_empty() {
                break;
            }

            // Create failed build steps for every build that depends on this, except when this
            // step is cached and is the top-level of that build (since then it's redundant with
            // the build's isCachedBuild field).
            {
                let mut db = self.db.get().await?;
                let mut tx = db.begin_transaction().await?;
                for b in &indirect {
                    if (job.result.step_status == BuildStatus::CachedFailure
                        && &b.drv_path == step.get_drv_path())
                        || ((job.result.step_status != BuildStatus::CachedFailure
                            && job.result.step_status != BuildStatus::Unsupported)
                            && job.build_id == b.id)
                        || b.get_finished_in_db()
                    {
                        continue;
                    }

                    tx.create_build_step(
                        None,
                        b.id,
                        &step.get_drv_path().get_full_path(),
                        step.get_system().as_deref(),
                        machine
                            .as_deref()
                            .map(|m| m.hostname.clone())
                            .unwrap_or_default(),
                        job.result.step_status,
                        job.result.error_msg.clone(),
                        if job.build_id == b.id {
                            None
                        } else {
                            Some(job.build_id)
                        },
                        step.get_outputs()
                            .unwrap_or_default()
                            .into_iter()
                            .map(|o| (o.name, o.path.map(|s| s.get_full_path())))
                            .collect(),
                    )
                    .await?;
                }

                // Mark all builds that depend on this derivation as failed.
                for b in &indirect {
                    if b.get_finished_in_db() {
                        continue;
                    }

                    log::info!("marking build {} as failed", b.id);
                    tx.update_build_after_failure(
                        b.id,
                        if &b.drv_path != step.get_drv_path()
                            && job.result.step_status == BuildStatus::Failed
                        {
                            BuildStatus::DepFailed
                        } else {
                            job.result.step_status
                        },
                        i32::try_from(
                            job.result
                                .start_time
                                .map(|s| s.timestamp())
                                .unwrap_or_default(),
                        )?, // TODO
                        i32::try_from(
                            job.result
                                .stop_time
                                .map(|s| s.timestamp())
                                .unwrap_or_default(),
                        )?, // TODO
                        job.result.step_status == BuildStatus::CachedFailure,
                    )
                    .await?;
                    self.metrics.nr_builds_done.add(1);
                }

                // Remember failed paths in the database so that they won't be built again.
                if job.result.step_status == BuildStatus::CachedFailure && job.result.can_cache {
                    for o in step.get_outputs().unwrap_or_default() {
                        let Some(p) = o.path else { continue };
                        tx.insert_failed_paths(&p.get_full_path()).await?;
                    }
                }

                tx.commit().await?;
            }

            {
                // Remove the indirect dependencies from 'builds'. This will cause them to be
                // destroyed.
                let mut current_builds = self.builds.write();
                for b in indirect {
                    b.set_finished_in_db(true);
                    current_builds.remove(&b.id);
                    dependent_ids.push(b.id);
                }
            }
        }
        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            tx.notify_build_finished(job.build_id, &dependent_ids)
                .await?;
            tx.commit().await?;
        }

        // trigger dispatch, as we now have a free mashine again
        self.trigger_dispatch();

        Ok(())
    }

    #[tracing::instrument(skip(self, step))]
    fn get_all_indirect_builds(&self, step: &Arc<Step>) -> AHashSet<Arc<Build>> {
        let mut indirect = AHashSet::new();
        let mut steps = AHashSet::new();
        step.get_dependents(&mut indirect, &mut steps);

        // If there are no builds left, delete all referring
        // steps from ‘steps’. As for the success case, we can
        // be certain no new referrers can be added.
        if indirect.is_empty() {
            let mut current_steps_map = self.steps.write();
            for s in steps {
                let drv = s.get_drv_path();
                log::debug!("finishing build step '{drv}'");
                current_steps_map.retain(|path, _| path != drv);
            }
        }

        indirect
    }

    #[tracing::instrument(skip(self, conn), err)]
    async fn create_jobset(
        &self,
        conn: &mut db::Connection,
        jobset_id: i32,
        project_name: &str,
        jobset_name: &str,
    ) -> anyhow::Result<Arc<Jobset>> {
        let key = (project_name.to_owned(), jobset_name.to_owned());
        {
            let jobsets = self.jobsets.read();
            if let Some(jobset) = jobsets.get(&key) {
                return Ok(jobset.clone());
            }
        }

        let shares = conn
            .get_jobset_scheduling_shares(jobset_id)
            .await?
            .ok_or(anyhow::anyhow!(
                "Scheduling Shares not found for jobset not found."
            ))?;
        let jobset = Jobset::new(jobset_id, project_name, jobset_name);
        jobset.set_shares(shares)?;

        for step in conn
            .get_jobset_build_steps(jobset_id, SCHEDULING_WINDOW)
            .await?
        {
            let Some(starttime) = step.starttime else {
                continue;
            };
            let Some(stoptime) = step.stoptime else {
                continue;
            };
            jobset.add_step(i64::from(starttime), i64::from(stoptime - starttime));
        }

        let jobset = Arc::new(jobset);
        {
            let mut jobsets = self.jobsets.write();
            jobsets.insert(key, jobset.clone());
        }

        Ok(jobset.clone())
    }

    #[tracing::instrument(skip(self, build, step), err)]
    async fn handle_previous_failure(
        &self,
        build: Arc<Build>,
        step: Arc<Step>,
    ) -> anyhow::Result<()> {
        // Some step previously failed, so mark the build as failed right away.
        log::warn!(
            "marking build {} as cached failure due to '{}'",
            build.id,
            step.get_drv_path()
        );
        if build.get_finished_in_db() {
            return Ok(());
        }

        // if !build.finished_in_db
        let mut conn = self.db.get().await?;
        let mut tx = conn.begin_transaction().await?;

        // Find the previous build step record, first by derivation path, then by output
        // path.
        let mut propagated_from = tx
            .get_last_build_step_id(&step.get_drv_path().get_full_path())
            .await?
            .unwrap_or_default();

        if propagated_from == 0 {
            // we can access step.drv here because the value is always set if
            // PreviousFailure is returned, so this should never yield None

            let outputs = step.get_outputs().unwrap_or_default();
            for o in outputs {
                let res = if let Some(path) = &o.path {
                    tx.get_last_build_step_id_for_output_path(&path.get_full_path())
                        .await
                } else {
                    tx.get_last_build_step_id_for_output_with_drv(
                        &step.get_drv_path().get_full_path(),
                        &o.name,
                    )
                    .await
                };
                if let Ok(Some(res)) = res {
                    propagated_from = res;
                    break;
                }
            }
        }

        tx.create_build_step(
            None,
            build.id,
            &step.get_drv_path().get_full_path(),
            step.get_system().as_deref(),
            String::new(),
            BuildStatus::CachedFailure,
            None,
            Some(propagated_from),
            step.get_outputs()
                .unwrap_or_default()
                .into_iter()
                .map(|o| (o.name, o.path.map(|s| s.get_full_path())))
                .collect(),
        )
        .await?;
        tx.update_build_after_previous_failure(
            build.id,
            if step.get_drv_path() == &build.drv_path {
                BuildStatus::Failed
            } else {
                BuildStatus::DepFailed
            },
        )
        .await?;

        let _ = tx.notify_build_finished(build.id, &[]).await;
        tx.commit().await?;

        build.set_finished_in_db(true);
        self.metrics.nr_builds_done.add(1);
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(
        self,
        build,
        nr_added,
        new_builds_by_id,
        new_builds_by_path,
        finished_drvs,
        new_runnable
    ), fields(build_id=build.id))]
    async fn create_build(
        &self,
        build: Arc<Build>,
        nr_added: Arc<AtomicI64>,
        new_builds_by_id: Arc<parking_lot::RwLock<AHashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: &AHashMap<nix_utils::StorePath, AHashSet<BuildID>>,
        finished_drvs: Arc<parking_lot::RwLock<AHashSet<nix_utils::StorePath>>>,
        new_runnable: Arc<parking_lot::RwLock<AHashSet<Arc<Step>>>>,
    ) {
        self.metrics.queue_build_loads.inc();
        log::info!("loading build {} ({})", build.id, build.full_job_name());
        nr_added.fetch_add(1, Ordering::Relaxed);
        {
            let mut new_builds_by_id = new_builds_by_id.write();
            new_builds_by_id.remove(&build.id);
        }

        if !nix_utils::check_if_storepath_exists(&build.drv_path).await {
            log::error!("aborting GC'ed build {}", build.id);
            if !build.get_finished_in_db() {
                match self.db.get().await {
                    Ok(mut conn) => {
                        if let Err(e) = conn.abort_build(build.id).await {
                            log::error!("Failed to abort the build={} e={}", build.id, e);
                        }
                    }
                    Err(e) => log::error!(
                        "Failed to get database connection so we can abort the build={} e={}",
                        build.id,
                        e
                    ),
                }
            }

            build.set_finished_in_db(true);
            self.metrics.nr_builds_done.add(1);
            return;
        }

        // Create steps for this derivation and its dependencies.
        let new_steps = Arc::new(parking_lot::RwLock::new(AHashSet::<Arc<Step>>::new()));
        let step = match self
            .create_step(
                // conn,
                build.clone(),
                build.drv_path.clone(),
                Some(build.clone()),
                None,
                finished_drvs.clone(),
                new_steps.clone(),
                new_runnable.clone(),
            )
            .await
        {
            CreateStepResult::None => None,
            CreateStepResult::Valid(dep) => Some(dep),
            CreateStepResult::PreviousFailure(step) => {
                if let Err(e) = self.handle_previous_failure(build, step).await {
                    log::error!("Failed to handle previous failure: {e}");
                }
                return;
            }
        };

        {
            use futures::stream::StreamExt as _;

            let builds = {
                let new_steps = new_steps.read();
                new_steps
                    .iter()
                    .filter_map(|r| Some(new_builds_by_path.get(r.get_drv_path())?.clone()))
                    .flatten()
                    .collect::<Vec<_>>()
            };
            let mut stream = futures::StreamExt::map(tokio_stream::iter(builds), |b| {
                let nr_added = nr_added.clone();
                let new_builds_by_id = new_builds_by_id.clone();
                let finished_drvs = finished_drvs.clone();
                let new_runnable = new_runnable.clone();
                async move {
                    let j = {
                        let new_builds_by_id = new_builds_by_id.read();
                        let Some(j) = new_builds_by_id.get(&b) else {
                            return;
                        };
                        j.clone()
                    };

                    Box::pin(self.create_build(
                        j,
                        nr_added,
                        new_builds_by_id,
                        new_builds_by_path,
                        finished_drvs,
                        new_runnable,
                    ))
                    .await;
                }
            })
            .buffered(10);
            while tokio_stream::StreamExt::next(&mut stream).await.is_some() {}
        }

        if let Some(step) = step {
            if !build.get_finished_in_db() {
                let mut builds = self.builds.write();
                builds.insert(build.id, build.clone());
            }

            build.set_toplevel_step(step.clone());
            build.propagate_priorities();

            let new_steps = new_steps.read();
            log::info!(
                "added build {} (top-level step {}, {} new steps)",
                build.id,
                step.get_drv_path(),
                new_steps.len()
            );
        } else {
            // If we didn't get a step, it means the step's outputs are
            // all valid. So we mark this as a finished, cached build.
            if let Err(e) = self.handle_cached_build(build).await {
                log::error!("failed to handle cached build: {e}");
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(
        self,
        build,
        referring_build,
        referring_step,
        finished_drvs,
        new_steps,
        new_runnable
    ), fields(build_id=build.id, %drv_path))]
    async fn create_step(
        &self,
        build: Arc<Build>,
        drv_path: nix_utils::StorePath,
        referring_build: Option<Arc<Build>>,
        referring_step: Option<Arc<Step>>,
        finished_drvs: Arc<parking_lot::RwLock<AHashSet<nix_utils::StorePath>>>,
        new_steps: Arc<parking_lot::RwLock<AHashSet<Arc<Step>>>>,
        new_runnable: Arc<parking_lot::RwLock<AHashSet<Arc<Step>>>>,
    ) -> CreateStepResult {
        use futures::stream::StreamExt as _;

        {
            let finished_drvs = finished_drvs.read();
            if finished_drvs.contains(&drv_path) {
                return CreateStepResult::None;
            }
        }

        let mut is_new = false;
        let step = {
            let mut steps = self.steps.write();
            let step = if let Some(step) = steps.get(&drv_path) {
                if let Some(step) = step.upgrade() {
                    step
                } else {
                    steps.remove(&drv_path);
                    is_new = true;
                    Step::new(drv_path.clone())
                }
            } else {
                is_new = true;
                Step::new(drv_path.clone())
            };

            {
                let mut state = step.state.write();
                if let Some(referring_build) = referring_build {
                    state.builds.push(Arc::downgrade(&referring_build));
                }
                if let Some(referring_step) = referring_step {
                    state.rdeps.push(Arc::downgrade(&referring_step));
                }
            }

            steps.insert(drv_path.clone(), Arc::downgrade(&step));
            step
        };

        if !is_new {
            return CreateStepResult::Valid(step);
        }
        self.metrics.queue_steps_created.inc();
        log::debug!("considering derivation '{drv_path}'");

        let Some(drv) = nix_utils::query_drv(&drv_path).await.ok().flatten() else {
            return CreateStepResult::None;
        };

        let use_substitutes = self.config.get_use_substitutes();
        // TODO: check all remote stores
        let remote_store = {
            let r = self.remote_stores.read();
            r.first().cloned()
        };
        let missing_outputs = if let Some(ref remote_store) = remote_store {
            let mut missing = remote_store
                .query_missing_remote_outputs(drv.outputs.clone())
                .await;
            if !missing.is_empty()
                && nix_utils::query_missing_outputs(drv.outputs.clone())
                    .await
                    .is_empty()
            {
                // we have all paths locally, so we can just upload them to the remote_store
                if let Ok(log_file) = self.construct_log_file_path(&drv_path).await {
                    let _ = self.uploader.schedule_upload(
                        missing.into_iter().filter_map(|v| v.path).collect(),
                        format!("log/{}", drv_path.base_name()),
                        log_file.to_string_lossy().to_string(),
                    );
                    missing = vec![];
                }
            }

            missing
        } else {
            nix_utils::query_missing_outputs(drv.outputs.clone()).await
        };

        step.set_drv(drv);

        if self.check_cached_failure(step.clone()).await {
            step.set_previous_failure(true);
            return CreateStepResult::PreviousFailure(step);
        }

        log::debug!("missing outputs: {missing_outputs:?}");
        let mut finished = missing_outputs.is_empty();
        if !missing_outputs.is_empty() && use_substitutes {
            use futures::stream::StreamExt as _;

            let mut substituted = 0;
            let missing_outputs_len = missing_outputs.len();
            let build_opts = nix_utils::BuildOptions::substitute_only();

            let mut stream = futures::StreamExt::map(tokio_stream::iter(missing_outputs), |o| {
                self.metrics.nr_substitutes_started.inc();
                crate::utils::substitute_output(
                    self.db.clone(),
                    self.store.clone(),
                    o,
                    build.id,
                    &drv_path,
                    &build_opts,
                    remote_store.as_ref(),
                )
            })
            .buffer_unordered(10);
            while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
                match v {
                    Ok(()) => {
                        self.metrics.nr_substitutes_succeeded.inc();
                        substituted += 1;
                    }
                    Err(e) => {
                        self.metrics.nr_substitutes_failed.inc();
                        log::warn!("Failed to substitute path: {e}");
                    }
                }
            }
            finished = substituted == missing_outputs_len;
        }

        if finished {
            let mut finished_drvs = finished_drvs.write();
            finished_drvs.insert(drv_path.clone());
            step.set_finished(true);
            return CreateStepResult::None;
        }

        log::debug!("creating build step '{drv_path}");
        let Some(input_drvs) = step.get_input_drvs() else {
            // this should never happen because we always a a drv set at this point in time
            return CreateStepResult::None;
        };

        let step2 = step.clone();
        let mut stream = futures::StreamExt::map(tokio_stream::iter(input_drvs), |i| {
            let build = build.clone();
            let step = step2.clone();
            let finished_drvs = finished_drvs.clone();
            let new_steps = new_steps.clone();
            let new_runnable = new_runnable.clone();
            async move {
                let path = nix_utils::StorePath::new(&i);
                Box::pin(self.create_step(
                    // conn,
                    build,
                    path,
                    None,
                    Some(step),
                    finished_drvs,
                    new_steps,
                    new_runnable,
                ))
                .await
            }
        })
        .buffered(25);
        while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
            match v {
                CreateStepResult::None => (),
                CreateStepResult::Valid(dep) => {
                    if !dep.get_finished() && !dep.get_previous_failure() {
                        // finished can be true if a step was returned, that already exists in
                        // self.steps and is currently being processed for completion
                        let mut state = step.state.write();
                        state.deps.insert(dep);
                    }
                }
                CreateStepResult::PreviousFailure(step) => {
                    return CreateStepResult::PreviousFailure(step);
                }
            }
        }

        {
            step.atomic_state.set_created(true);
            if step.get_deps_size() == 0 {
                let mut new_runnable = new_runnable.write();
                new_runnable.insert(step.clone());
            }
        }

        {
            let mut new_steps = new_steps.write();
            new_steps.insert(step.clone());
        }
        CreateStepResult::Valid(step)
    }

    #[tracing::instrument(skip(self, step), ret, level = "debug")]
    async fn check_cached_failure(&self, step: Arc<Step>) -> bool {
        let Some(drv_outputs) = step.get_outputs() else {
            return false;
        };

        let Ok(mut conn) = self.db.get().await else {
            return false;
        };

        conn.check_if_paths_failed(
            &drv_outputs
                .iter()
                .filter_map(|o| o.path.as_ref().map(nix_utils::StorePath::get_full_path))
                .collect::<Vec<_>>(),
        )
        .await
        .unwrap_or_default()
    }

    #[tracing::instrument(skip(self), err)]
    async fn handle_jobset_change(&self) -> anyhow::Result<()> {
        let curr_jobsets_in_db = self.db.get().await?.get_jobsets().await?;

        let jobsets = self.jobsets.read();
        for row in curr_jobsets_in_db {
            if let Some(i) = jobsets.get(&(row.project.clone(), row.name.clone())) {
                if let Err(e) = i.set_shares(row.schedulingshares) {
                    log::error!(
                        "Failed to update jobset scheduling shares. project_name={} jobset_name={} e={}",
                        row.project,
                        row.name,
                        e,
                    );
                }
            }
        }

        Ok(())
    }

    #[tracing::instrument(skip(self, build), fields(build_id=build.id), err)]
    async fn handle_cached_build(&self, build: Arc<Build>) -> anyhow::Result<()> {
        let res = self.get_build_output_cached(&build.drv_path).await?;

        for (_, path) in &res.outputs {
            self.add_root(path);
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;

            log::info!("marking build {} as succeeded (cached)", build.id);
            let now = chrono::Utc::now().timestamp();
            tx.mark_succeeded_build(
                get_mark_build_sccuess_data(&build, &res),
                true,
                i32::try_from(now)?, // TODO
                i32::try_from(now)?, // TODO
            )
            .await?;
            self.metrics.nr_builds_done.add(1);

            tx.notify_build_finished(build.id, &[]).await?;
            tx.commit().await?;
        }
        build.set_finished_in_db(true);

        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    async fn get_build_output_cached(
        &self,
        drv_path: &nix_utils::StorePath,
    ) -> anyhow::Result<BuildOutput> {
        let drv = nix_utils::query_drv(drv_path)
            .await?
            .ok_or(anyhow::anyhow!("Derivation not found"))?;

        {
            let mut db = self.db.get().await?;
            for o in &drv.outputs {
                let Some(out_path) = &o.path else {
                    continue;
                };
                let Some(db_build_output) = db
                    .get_build_output_for_path(&out_path.get_full_path())
                    .await?
                else {
                    continue;
                };
                let build_id = db_build_output.id;
                let Ok(mut res): anyhow::Result<BuildOutput> = db_build_output.try_into() else {
                    continue;
                };

                res.products = db
                    .get_build_products_for_build_id(build_id)
                    .await?
                    .into_iter()
                    .map(Into::into)
                    .collect();
                res.metrics = db
                    .get_build_metrics_for_build_id(build_id)
                    .await?
                    .into_iter()
                    .map(|v| (v.name.clone(), v.into()))
                    .collect();

                return Ok(res);
            }
        }

        BuildOutput::new(&self.store, drv.outputs).await
    }

    fn add_root(&self, drv_path: &nix_utils::StorePath) {
        let roots_dir = self.config.get_roots_dir();
        nix_utils::add_root(&roots_dir, drv_path);
    }

    async fn abort_unsupported(&self) {
        let runnable = {
            let mut steps = self.steps.write();
            steps.retain(|_, s| s.upgrade().is_some());
            steps
                .iter()
                .filter_map(|(_, s)| s.upgrade())
                .filter(|v| v.get_runnable())
                .collect::<Vec<_>>()
        };

        let now = chrono::Utc::now();

        let mut aborted = AHashSet::new();
        let mut count = 0;

        let max_unsupported_time = self.config.get_max_unsupported_time();
        for step in &runnable {
            let supported = self.machines.support_step(step);
            if supported {
                step.set_last_supported_now();
                continue;
            }

            count += 1;
            if (now - step.get_last_supported()) < max_unsupported_time {
                continue;
            }

            let drv = step.get_drv_path();
            let system = step.get_system();
            log::error!("aborting unsupported build step '{drv}' (type '{system:?}')",);

            aborted.insert(step.clone());

            let mut dependents = AHashSet::new();
            let mut steps = AHashSet::new();
            step.get_dependents(&mut dependents, &mut steps);
            // Maybe the step got cancelled.
            if dependents.is_empty() {
                continue;
            }

            // Find the build that has this step as the top-level (if any).
            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or(dependents.iter().next())
            else {
                // this should never happen, as we checked is_empty above and fallback is just any build
                continue;
            };

            let mut job = machine::Job::new(build.id, drv.to_owned(), None);
            job.result.start_time = Some(now);
            job.result.stop_time = Some(now);
            job.result.step_status = BuildStatus::Unsupported;
            job.result.error_msg = Some(format!(
                "unsupported system type '{}'",
                system.unwrap_or(String::new())
            ));
            if let Err(e) = self.inner_fail_job(drv, None, job, step.clone()).await {
                log::error!("Failed to fail step drv={drv} e={e}");
            }
        }

        {
            let mut queues = self.queues.write().await;
            for step in &aborted {
                queues.remove_job_by_path(step.get_drv_path());
            }
            queues.remove_all_weak_pointer();
        }
        self.metrics.nr_unsupported_steps.set(count);
        self.metrics
            .nr_unsupported_steps_aborted
            .add(i64::try_from(aborted.len()).unwrap_or_default());
    }
}
