mod atomic;
mod build;
mod fod_checker;
mod jobset;
mod machine;
mod metrics;
mod queue;
mod step;
mod step_info;
mod uploader;

pub use atomic::AtomicDateTime;
pub use build::{Build, BuildOutput, BuildResultState, BuildTimings, Builds, RemoteBuild};
pub use jobset::{Jobset, JobsetID, Jobsets};
pub use machine::{Machine, Message as MachineMessage, Pressure, Stats as MachineStats};
pub use queue::{BuildQueueStats, Queues};
pub use step::{Step, Steps};
pub use step_info::StepInfo;

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Instant;

use futures::TryStreamExt as _;
use hashbrown::{HashMap, HashSet};
use secrecy::ExposeSecret as _;

use db::models::{BuildID, BuildStatus};
use nix_utils::BaseStore as _;

use crate::config::{App, Cli};
use crate::state::build::get_mark_build_sccuess_data;
pub use crate::state::fod_checker::FodChecker;
use crate::state::machine::Machines;
use crate::utils::finish_build_step;

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
    pub remote_stores: parking_lot::RwLock<Vec<binary_cache::S3BinaryCacheClient>>,
    pub config: App,
    pub cli: Cli,
    pub db: db::Database,

    pub machines: Machines,

    pub log_dir: std::path::PathBuf,

    pub builds: Builds,
    pub jobsets: Jobsets,
    pub steps: Steps,
    pub queues: Queues,

    pub fod_checker: Option<Arc<FodChecker>>,

    pub started_at: jiff::Timestamp,

    pub metrics: metrics::PromMetrics,
    pub notify_dispatch: tokio::sync::Notify,
    pub uploader: uploader::Uploader,
}

impl State {
    #[tracing::instrument(skip(tracing_guard), err)]
    pub async fn new(tracing_guard: &hydra_tracing::TracingGuard) -> anyhow::Result<Arc<Self>> {
        let store = nix_utils::LocalStore::init();
        nix_utils::set_verbosity(1);
        let cli = Cli::new();
        if cli.status {
            tracing_guard.change_log_level(hydra_tracing::EnvFilter::new("error"));
        }

        let config = App::init(&cli.config_path)?;
        let log_dir = config.get_hydra_log_dir();
        let db = db::Database::new(
            config.get_db_url().expose_secret(),
            config.get_max_db_connections(),
        )
        .await?;

        let _ = fs_err::tokio::create_dir_all(&log_dir).await;

        let mut remote_stores = vec![];
        for uri in config.get_remote_store_addrs() {
            remote_stores.push(binary_cache::S3BinaryCacheClient::new(uri.parse()?).await?);
        }

        Ok(Arc::new(Self {
            store,
            remote_stores: parking_lot::RwLock::new(remote_stores),
            cli,
            db,
            machines: Machines::new(),
            log_dir,
            builds: Builds::new(),
            jobsets: Jobsets::new(),
            steps: Steps::new(),
            queues: Queues::new(),
            fod_checker: if config.get_enable_fod_checker() {
                Some(Arc::new(FodChecker::new(None)))
            } else {
                None
            },
            started_at: jiff::Timestamp::now(),
            metrics: metrics::PromMetrics::new()?,
            notify_dispatch: tokio::sync::Notify::new(),
            uploader: uploader::Uploader::new(),
            config,
        }))
    }

    #[tracing::instrument(skip(self, new_config), err)]
    pub async fn reload_config_callback(
        &self,
        new_config: &crate::config::PreparedApp,
    ) -> anyhow::Result<()> {
        // IF this gets more complex we need a way to trap the state and revert.
        // right now it doesnt matter because only reconfigure_pool can fail and this is the first
        // thing we do.

        let curr_db_url = self.config.get_db_url();
        let curr_machine_sort_fn = self.config.get_machine_sort_fn();
        let curr_step_sort_fn = self.config.get_step_sort_fn();
        let curr_remote_stores = self.config.get_remote_store_addrs();
        let curr_enable_fod_checker = self.config.get_enable_fod_checker();
        let mut new_remote_stores = vec![];
        if curr_remote_stores != new_config.remote_store_addr {
            for uri in &new_config.remote_store_addr {
                new_remote_stores.push(binary_cache::S3BinaryCacheClient::new(uri.parse()?).await?);
            }
        }

        if curr_db_url.expose_secret() != new_config.db_url.expose_secret() {
            self.db
                .reconfigure_pool(new_config.db_url.expose_secret())?;
        }
        if curr_machine_sort_fn != new_config.machine_sort_fn {
            self.machines.sort(new_config.machine_sort_fn);
        }
        if curr_step_sort_fn != new_config.step_sort_fn {
            self.queues.sort_queues(curr_step_sort_fn).await;
        }
        if curr_remote_stores != new_config.remote_store_addr {
            let mut remote_stores = self.remote_stores.write();
            *remote_stores = new_remote_stores;
        }

        if curr_enable_fod_checker != new_config.enable_fod_checker {
            tracing::warn!(
                "Changing the value of enable_fod_checker currently requires a restart!"
            );
        }

        self.machines
            .publish_new_config(machine::ConfigUpdate {
                max_concurrent_downloads: new_config.max_concurrent_downloads,
            })
            .await;

        Ok(())
    }

    #[tracing::instrument(skip(self, machine))]
    pub async fn insert_machine(&self, machine: Machine) -> uuid::Uuid {
        if !machine.systems.is_empty() {
            self.queues
                .ensure_queues_for_systems(&machine.systems)
                .await;
        }

        let machine_id = self
            .machines
            .insert_machine(machine, self.config.get_machine_sort_fn());
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
                        machine_id,
                        &job.path,
                        // we fail this with preparing because we kinda want to restart all jobs if
                        // a machine is removed
                        BuildResultState::PreparingFailure,
                        BuildTimings::default(),
                    )
                    .await
                {
                    tracing::error!(
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

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_busy(&self) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;
        db.clear_busy(0).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, constraint), err)]
    #[allow(clippy::too_many_lines)]
    async fn realise_drv_on_valid_machine(
        self: Arc<Self>,
        constraint: queue::JobConstraint,
    ) -> anyhow::Result<RealiseStepResult> {
        let free_fn = self.config.get_machine_free_fn();

        let Some((machine, step_info)) = constraint.resolve(&self.machines, free_fn) else {
            return Ok(RealiseStepResult::None);
        };
        let drv = step_info.step.get_drv_path();
        let mut build_options = nix_utils::BuildOptions::new(None);

        let build_id = {
            let mut dependents = HashSet::new();
            let mut steps = HashSet::new();
            step_info.step.get_dependents(&mut dependents, &mut steps);

            if dependents.is_empty() {
                // Apparently all builds that depend on this derivation are gone (e.g. cancelled). So
                // don't bother. This is very unlikely to happen, because normally Steps are only kept
                // alive by being reachable from a Build. However, it's possible that a new Build just
                // created a reference to this step. So to handle that possibility, we retry this step
                // (putting it back in the runnable queue). If there are really no strong pointers to
                // the step, it will be deleted.
                tracing::info!("maybe cancelling build step {drv}");
                return Ok(RealiseStepResult::MaybeCancelled);
            }

            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or_else(|| dependents.iter().next())
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
        job.result.set_start_time_now();
        if self.check_cached_failure(step_info.step.clone()).await {
            job.result.step_status = BuildStatus::CachedFailure;
            self.inner_fail_job(drv, None, job, step_info.step.clone())
                .await?;
            return Ok(RealiseStepResult::CachedFailure);
        }

        self.construct_log_file_path(drv)
            .await?
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("failed to construct log path string."))?
            .clone_into(&mut job.result.log_file);
        let step_nr = {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;

            let step_nr = tx
                .create_build_step(
                    Some(job.result.get_start_time_as_i32()?),
                    build_id,
                    &self.store.print_store_path(step_info.step.get_drv_path()),
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
                        .map(|o| (o.name, o.path.map(|s| self.store.print_store_path(&s))))
                        .collect(),
                )
                .await?;
            tx.commit().await?;
            step_nr
        };
        job.step_nr = step_nr;

        tracing::info!(
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
        machine
            .build_drv(
                job,
                &build_options,
                // TODO: cleanup
                if self.config.use_presigned_uploads() {
                    let remote_stores = self.remote_stores.read();
                    remote_stores
                        .first()
                        .map(|s| crate::state::machine::PresignedUrlOpts {
                            upload_debug_info: s.cfg.write_debug_info,
                        })
                } else {
                    None
                },
            )
            .await?;
        self.metrics.nr_steps_started.inc();
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
        let _ = fs_err::tokio::create_dir_all(&log_file).await; // create dir
        log_file.push(file);
        Ok(log_file)
    }

    #[tracing::instrument(skip(self), fields(%drv), err)]
    pub async fn new_log_file(
        &self,
        drv: &nix_utils::StorePath,
    ) -> anyhow::Result<fs_err::tokio::File> {
        let log_file = self.construct_log_file_path(drv).await?;
        tracing::debug!("opening {log_file:?}");

        Ok(fs_err::tokio::File::options()
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
        new_builds_by_id: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: HashMap<nix_utils::StorePath, HashSet<BuildID>>,
    ) {
        let finished_drvs = Arc::new(parking_lot::RwLock::new(
            HashSet::<nix_utils::StorePath>::new(),
        ));

        let starttime = jiff::Timestamp::now();
        for id in new_ids {
            let Some(build) = new_builds_by_id.read().get(&id).cloned() else {
                continue;
            };

            let new_runnable = Arc::new(parking_lot::RwLock::new(HashSet::<Arc<Step>>::new()));
            let nr_added: Arc<AtomicI64> = Arc::new(0.into());
            let now = Instant::now();

            Box::pin(self.create_build(
                build,
                nr_added.clone(),
                new_builds_by_id.clone(),
                &new_builds_by_path,
                finished_drvs.clone(),
                new_runnable.clone(),
            ))
            .await;

            // we should never run into this issue
            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .build_read_time_ms
                .inc_by(now.elapsed().as_millis() as u64);

            {
                let new_runnable = new_runnable.read();
                tracing::info!(
                    "got {} new runnable steps from {} new builds",
                    new_runnable.len(),
                    nr_added.load(Ordering::Relaxed)
                );
                for r in new_runnable.iter() {
                    r.make_runnable();
                }
            }
            if let Ok(added_u64) = u64::try_from(nr_added.load(Ordering::Relaxed)) {
                self.metrics.nr_builds_read.inc_by(added_u64);
            }
            let stop_queue_run_after = self.config.get_stop_queue_run_after();

            if let Some(stop_queue_run_after) = stop_queue_run_after
                && jiff::Timestamp::now() > (starttime + stop_queue_run_after)
            {
                self.metrics.queue_checks_early_exits.inc();
                break;
            }
        }

        // This is here to ensure that we dont have any deps to finished steps
        // This can happen because step creation is async and is_new can return a step that is
        // still undecided if its finished or not.
        self.steps.make_rdeps_runnable();

        // we can just always trigger dispatch as we might have a free machine and its cheap
        self.metrics.queue_checks_finished.inc();
        self.trigger_dispatch();
        if let Some(fod_checker) = &self.fod_checker {
            fod_checker.trigger_traverse();
        }
    }

    #[tracing::instrument(skip(self), err)]
    async fn process_queue_change(&self) -> anyhow::Result<()> {
        let mut db = self.db.get().await?;
        let curr_ids: HashMap<_, _> = db
            .get_not_finished_builds_fast()
            .await?
            .into_iter()
            .map(|b| (b.id, b.globalpriority))
            .collect();
        self.builds.update_priorities(&curr_ids);

        let cancelled_steps = self.queues.kill_active_steps().await;
        for (drv_path, machine_id) in cancelled_steps {
            if let Err(e) = self
                .fail_step(
                    machine_id,
                    &drv_path,
                    BuildResultState::Cancelled,
                    BuildTimings::default(),
                )
                .await
            {
                tracing::error!(
                    "Failed to abort step machine_id={machine_id} drv={drv_path} e={e}",
                );
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
        let drv = nix_utils::query_drv(&self.store, drv_path)
            .await?
            .ok_or_else(|| anyhow::anyhow!("drv not found"))?;
        db.insert_debug_build(
            jobset_id,
            &self.store.print_store_path(drv_path),
            &drv.system,
        )
        .await?;

        let mut tx = db.begin_transaction().await?;
        tx.notify_builds_added().await?;
        tx.commit().await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_queued_builds(&self) -> anyhow::Result<()> {
        self.metrics.queue_checks_started.inc();

        let mut new_ids = Vec::<BuildID>::with_capacity(1000);
        let mut new_builds_by_id = HashMap::<BuildID, Arc<Build>>::with_capacity(1000);
        let mut new_builds_by_path =
            HashMap::<nix_utils::StorePath, HashSet<BuildID>>::with_capacity(1000);

        {
            let mut conn = self.db.get().await?;
            for b in conn.get_not_finished_builds().await? {
                let jobset = self
                    .jobsets
                    .create(&mut conn, b.jobset_id, &b.project, &b.jobset)
                    .await?;
                let build = Build::new(b, jobset)?;
                new_ids.push(build.id);
                new_builds_by_id.insert(build.id, build.clone());
                new_builds_by_path
                    .entry(build.drv_path.clone())
                    .or_insert_with(HashSet::new)
                    .insert(build.id);
            }
        }
        tracing::debug!("new_ids: {new_ids:?}");
        tracing::debug!("new_builds_by_id: {new_builds_by_id:?}");
        tracing::debug!("new_builds_by_path: {new_builds_by_path:?}");

        let new_builds_by_id = Arc::new(parking_lot::RwLock::new(new_builds_by_id));
        Box::pin(self.process_new_builds(new_ids, new_builds_by_id, new_builds_by_path)).await;
        Ok(())
    }

    #[tracing::instrument(skip(self))]
    pub fn start_queue_monitor_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                if let Err(e) = Box::pin(self.queue_monitor_loop()).await {
                    tracing::error!("Failed to spawn queue monitor loop. e={e}");
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
                tracing::error!("get_queue_builds failed inside queue monitor loop: {e}");
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
                            tracing::warn!("PgListener failed with e={e}");
                            continue;
                        }
                    },
                }
            } else {
                match listener.try_next().await {
                    Ok(Some(v)) => v.channel().to_owned(),
                    Ok(None) => continue,
                    Err(e) => {
                        tracing::warn!("PgListener failed with e={e}");
                        continue;
                    }
                }
            };
            self.metrics.nr_queue_wakeups.inc();
            tracing::trace!("New notification from PgListener. notification={notification:?}");

            match notification.as_ref() {
                "builds_added" => {
                    tracing::debug!("got notification: new builds added to the queue");
                }
                "builds_restarted" => tracing::debug!("got notification: builds restarted"),
                "builds_cancelled" | "builds_deleted" | "builds_bumped" => {
                    tracing::info!("got notification: builds cancelled or bumped");
                    if let Err(e) = self.process_queue_change().await {
                        tracing::error!("Failed to process queue change. e={e}");
                    }
                }
                "jobset_shares_changed" => {
                    tracing::info!("got notification: jobset shares changed");
                    match self.db.get().await {
                        Ok(mut conn) => {
                            if let Err(e) = self.jobsets.handle_change(&mut conn).await {
                                tracing::error!("Failed to handle jobset change. e={e}");
                            }
                        }
                        Err(e) => {
                            tracing::error!(
                                "Failed to get db connection for event 'jobset_shares_changed'. e={e}"
                            );
                        }
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
                    tracing::info!("starting dispatch");

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_waiting
                        .inc_by(before_sleep.elapsed().as_micros() as u64);

                    self.metrics.nr_dispatcher_wakeups.inc();
                    let before_work = Instant::now();
                    self.clone().do_dispatch_once().await;

                    let elapsed = before_work.elapsed();

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_running
                        .inc_by(elapsed.as_micros() as u64);

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatch_time_ms
                        .inc_by(elapsed.as_millis() as u64);
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self), err)]
    async fn dump_status_loop(self: Arc<Self>) -> anyhow::Result<()> {
        let mut listener = self.db.listener(vec!["dump_status"]).await?;

        let state = self.clone();
        loop {
            let _ = match listener.try_next().await {
                Ok(Some(v)) => v,
                Ok(None) => continue,
                Err(e) => {
                    tracing::warn!("PgListener failed with e={e}");
                    continue;
                }
            };

            let state = state.clone();
            let queue_stats = crate::io::QueueRunnerStats::new(state.clone()).await;
            let sort_fn = state.config.get_machine_sort_fn();
            let free_fn = state.config.get_machine_free_fn();
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
            let jobsets = self.jobsets.clone_as_io();
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
                        tracing::error!("Failed to update status in database: {e}");
                        continue;
                    }
                };
                if let Err(e) = tx.upsert_status(&dump_status).await {
                    tracing::error!("Failed to update status in database: {e}");
                    continue;
                }
                if let Err(e) = tx.notify_status_dumped().await {
                    tracing::error!("Failed to update status in database: {e}");
                    continue;
                }
                if let Err(e) = tx.commit().await {
                    tracing::error!("Failed to update status in database: {e}");
                }
            }
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn start_dump_status_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                if let Err(e) = self.dump_status_loop().await {
                    tracing::error!("Failed to spawn queue monitor loop. e={e}");
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
                tracing::warn!("PgListener failed with e={e}");
                return Ok(());
            }
        };
        if let Some(status) = db.get_status().await? {
            // we want a println! here so it can be consumed by other tools
            println!("{}", serde_json::to_string_pretty(&status)?);
        }

        Ok(())
    }

    #[tracing::instrument(skip(self))]
    pub fn trigger_dispatch(&self) {
        self.notify_dispatch.notify_one();
    }

    #[tracing::instrument(skip(self))]
    async fn do_dispatch_once(self: Arc<Self>) {
        // Prune old historical build step info from the jobsets.
        self.jobsets.prune();
        let new_runnable = self.steps.clone_runnable();

        let now = jiff::Timestamp::now();
        let mut new_queues = HashMap::<System, Vec<StepInfo>>::with_capacity(10);
        for r in new_runnable {
            let Some(system) = r.get_system() else {
                continue;
            };
            if r.atomic_state.tries.load(Ordering::Relaxed) > 0 {
                continue;
            }
            let step_info = StepInfo::new(&self.store, r.clone()).await;

            new_queues
                .entry(system)
                .or_insert_with(|| Vec::with_capacity(100))
                .push(step_info);
        }

        for (system, jobs) in new_queues {
            self.queues
                .insert_new_jobs(
                    system,
                    jobs,
                    &now,
                    self.config.get_step_sort_fn(),
                    &self.metrics,
                )
                .await;
        }
        self.queues.remove_all_weak_pointer().await;

        let nr_steps_waiting_all_queues = self
            .queues
            .process(
                {
                    let state = self.clone();
                    async move |constraint: queue::JobConstraint| {
                        Box::pin(state.clone().realise_drv_on_valid_machine(constraint)).await
                    }
                },
                &self.metrics,
            )
            .await;
        self.metrics
            .nr_steps_waiting
            .set(nr_steps_waiting_all_queues);

        self.abort_unsupported().await;
    }

    #[tracing::instrument(skip(self, step_status), fields(%build_id, %machine_id), err)]
    pub async fn update_build_step(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        step_status: db::models::StepStatus,
    ) -> anyhow::Result<()> {
        let build_id_and_step_nr = self.machines.get_machine_by_id(machine_id).and_then(|m| {
            tracing::debug!(
                "get job from machine by build_id: build_id={build_id} m={}",
                m.id
            );
            m.get_build_id_and_step_nr_by_uuid(build_id)
        });

        let Some((build_id, step_nr)) = build_id_and_step_nr else {
            tracing::warn!(
                "Failed to find job with build_id and step_nr for build_id={build_id:?} machine_id={machine_id:?}."
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
    #[tracing::instrument(skip(self, output), fields(%machine_id, %drv_path), err)]
    pub async fn succeed_step(
        &self,
        machine_id: uuid::Uuid,
        drv_path: &nix_utils::StorePath,
        output: BuildOutput,
    ) -> anyhow::Result<()> {
        tracing::info!("marking job as done: drv_path={drv_path}");
        let item = self
            .queues
            .remove_job_from_scheduled(drv_path)
            .await
            .ok_or_else(|| anyhow::anyhow!("Step is missing in queues.scheduled"))?;

        item.step_info.step.set_finished(true);
        tracing::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            item.machine.id
        );
        let mut job = item
            .machine
            .remove_job(drv_path)
            .ok_or_else(|| anyhow::anyhow!("Job is missing in machine.jobs m={}", item.machine,))?;
        self.queues
            .remove_job(&item.step_info, &item.build_queue)
            .await;

        job.result.step_status = BuildStatus::Success;
        job.result.set_stop_time_now();
        job.result.set_overhead(output.timings.get_overhead())?;

        let total_step_time = job.result.get_total_step_time_ms();
        item.machine
            .stats
            .track_build_success(output.timings, total_step_time);
        self.metrics
            .track_build_success(output.timings, total_step_time);

        finish_build_step(
            &self.db,
            &self.store,
            job.build_id,
            job.step_nr,
            &job.result,
            Some(item.machine.hostname.clone()),
        )
        .await?;

        // TODO: redo gc roots, we only need to root until we are done with that build
        for (_, path) in &output.outputs {
            self.add_root(path);
        }

        let has_stores = {
            let r = self.remote_stores.read();
            !r.is_empty()
        };
        if has_stores {
            // Only upload outputs if presigned uploads are NOT enabled
            // When presigned uploads are enabled, builder handles NAR uploads directly
            let outputs_to_upload = if self.config.use_presigned_uploads() {
                vec![]
            } else {
                output
                    .outputs
                    .values()
                    .map(Clone::clone)
                    .collect::<Vec<_>>()
            };

            if let Err(e) = self.uploader.schedule_upload(
                outputs_to_upload,
                format!("log/{}", job.path.base_name()),
                job.result.log_file.clone(),
            ) {
                tracing::error!(
                    "Failed to schedule upload for build {} outputs: {}",
                    job.build_id,
                    e
                );
            }
        }

        let direct = item.step_info.step.get_direct_builds();
        if direct.is_empty() {
            self.steps.remove(item.step_info.step.get_drv_path());
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            let start_time = job.result.get_start_time_as_i32()?;
            let stop_time = job.result.get_stop_time_as_i32()?;
            for b in &direct {
                let is_cached = job.build_id != b.id || job.result.is_cached;
                tx.mark_succeeded_build(
                    get_mark_build_sccuess_data(&self.store, b, &output),
                    is_cached,
                    start_time,
                    stop_time,
                )
                .await?;
                self.metrics.nr_builds_done.inc();
            }

            tx.commit().await?;
        }

        // Remove the direct dependencies from 'builds'. This will cause them to be
        // destroyed.
        for b in &direct {
            b.set_finished_in_db(true);
            self.builds.remove_by_id(b.id);
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            for b in direct {
                tx.notify_build_finished(b.id, &[]).await?;
            }

            tx.commit().await?;
        }

        item.step_info.step.make_rdeps_runnable();

        // always trigger dispatch, as we now might have a free machine again
        self.trigger_dispatch();

        Ok(())
    }

    #[tracing::instrument(skip(self), fields(%machine_id, %drv_path), err)]
    pub async fn fail_step(
        &self,
        machine_id: uuid::Uuid,
        drv_path: &nix_utils::StorePath,
        state: BuildResultState,
        timings: BuildTimings,
    ) -> anyhow::Result<()> {
        tracing::info!("removing job from running in system queue: drv_path={drv_path}");
        let item = self
            .queues
            .remove_job_from_scheduled(drv_path)
            .await
            .ok_or_else(|| anyhow::anyhow!("Step is missing in queues.scheduled"))?;

        item.step_info.step.set_finished(false);

        tracing::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            item.machine.id
        );
        let mut job = item
            .machine
            .remove_job(drv_path)
            .ok_or_else(|| anyhow::anyhow!("Job is missing in machine.jobs m={}", item.machine))?;

        job.result.step_status = BuildStatus::Failed;
        // this can override step_status to something more specific
        job.result.update_with_result_state(&state);
        job.result.set_stop_time_now();
        job.result.set_overhead(timings.get_overhead())?;

        let total_step_time = job.result.get_total_step_time_ms();
        item.machine
            .stats
            .track_build_failure(timings, total_step_time);
        self.metrics.track_build_failure(timings, total_step_time);

        let (max_retries, retry_interval, retry_backoff) = self.config.get_retry();

        if job.result.can_retry {
            item.step_info
                .step
                .atomic_state
                .tries
                .fetch_add(1, Ordering::Relaxed);
            let tries = item
                .step_info
                .step
                .atomic_state
                .tries
                .load(Ordering::Relaxed);
            if tries < max_retries {
                self.metrics.nr_retries.inc();
                #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
                let delta = (retry_interval * retry_backoff.powf((tries - 1) as f32)) as i64;
                tracing::info!("will retry '{drv_path}' after {delta}s");
                item.step_info
                    .step
                    .set_after(jiff::Timestamp::now() + jiff::SignedDuration::from_secs(delta));
                if i64::from(tries) > self.metrics.max_nr_retries.get() {
                    self.metrics.max_nr_retries.set(i64::from(tries));
                }

                item.step_info.set_already_scheduled(false);

                finish_build_step(
                    &self.db,
                    &self.store,
                    job.build_id,
                    job.step_nr,
                    &job.result,
                    Some(item.machine.hostname.clone()),
                )
                .await?;
                self.trigger_dispatch();
                return Ok(());
            }
        }

        // remove job from queues, aka actually fail the job
        self.queues
            .remove_job(&item.step_info, &item.build_queue)
            .await;

        self.inner_fail_job(
            drv_path,
            Some(item.machine),
            job,
            item.step_info.step.clone(),
        )
        .await
    }

    #[tracing::instrument(skip(self, output), fields(%machine_id, build_id=%build_id), err)]
    pub async fn succeed_step_by_uuid(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        output: BuildOutput,
    ) -> anyhow::Result<()> {
        let machine = self
            .machines
            .get_machine_by_id(machine_id)
            .ok_or_else(|| anyhow::anyhow!("Machine with machine_id not found"))?;
        let drv_path = machine
            .get_job_drv_for_build_id(build_id)
            .ok_or_else(|| anyhow::anyhow!("Job with build_id not found"))?;

        self.succeed_step(machine_id, &drv_path, output).await
    }

    #[tracing::instrument(skip(self), fields(%machine_id, build_id=%build_id), err)]
    pub async fn fail_step_by_uuid(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        state: BuildResultState,
        timings: BuildTimings,
    ) -> anyhow::Result<()> {
        let machine = self
            .machines
            .get_machine_by_id(machine_id)
            .ok_or_else(|| anyhow::anyhow!("Machine with machine_id not found"))?;
        let drv_path = machine
            .get_job_drv_for_build_id(build_id)
            .ok_or_else(|| anyhow::anyhow!("Job with build_id not found"))?;

        self.fail_step(machine_id, &drv_path, state, timings).await
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
        if !job.result.has_stop_time() {
            job.result.set_stop_time_now();
        }

        if job.step_nr != 0 {
            finish_build_step(
                &self.db,
                &self.store,
                job.build_id,
                job.step_nr,
                &job.result,
                machine.as_ref().map(|m| m.hostname.clone()),
            )
            .await?;
        }

        let mut dependent_ids = Vec::new();
        let mut step_finished = false;
        loop {
            let indirect = self.get_all_indirect_builds(&step);
            if indirect.is_empty() && step_finished {
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
                        &self.store.print_store_path(step.get_drv_path()),
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
                            .map(|o| (o.name, o.path.map(|s| self.store.print_store_path(&s))))
                            .collect(),
                    )
                    .await?;
                }

                // Mark all builds that depend on this derivation as failed.
                for b in &indirect {
                    if b.get_finished_in_db() {
                        continue;
                    }

                    tracing::info!("marking build {} as failed", b.id);
                    let start_time = job.result.get_start_time_as_i32()?;
                    let stop_time = job.result.get_stop_time_as_i32()?;
                    tx.update_build_after_failure(
                        b.id,
                        if &b.drv_path != step.get_drv_path()
                            && job.result.step_status == BuildStatus::Failed
                        {
                            BuildStatus::DepFailed
                        } else {
                            job.result.step_status
                        },
                        start_time,
                        stop_time,
                        job.result.step_status == BuildStatus::CachedFailure,
                    )
                    .await?;
                    self.metrics.nr_builds_done.inc();
                }

                // Remember failed paths in the database so that they won't be built again.
                if job.result.step_status != BuildStatus::CachedFailure && job.result.can_cache {
                    for o in step.get_outputs().unwrap_or_default() {
                        let Some(p) = o.path else { continue };
                        tx.insert_failed_paths(&self.store.print_store_path(&p))
                            .await?;
                    }
                }

                tx.commit().await?;
            }

            step_finished = true;

            // Remove the indirect dependencies from 'builds'. This will cause them to be
            // destroyed.
            for b in indirect {
                b.set_finished_in_db(true);
                self.builds.remove_by_id(b.id);
                dependent_ids.push(b.id);
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
    fn get_all_indirect_builds(&self, step: &Arc<Step>) -> HashSet<Arc<Build>> {
        let mut indirect = HashSet::new();
        let mut steps = HashSet::new();
        step.get_dependents(&mut indirect, &mut steps);

        // If there are no builds left, delete all referring
        // steps from ‘steps’. As for the success case, we can
        // be certain no new referrers can be added.
        if indirect.is_empty() {
            for s in steps {
                let drv = s.get_drv_path();
                tracing::debug!("finishing build step '{drv}'");
                self.steps.remove(drv);
            }
        }

        indirect
    }

    #[tracing::instrument(skip(self, build, step), err)]
    async fn handle_previous_failure(
        &self,
        build: Arc<Build>,
        step: Arc<Step>,
    ) -> anyhow::Result<()> {
        // Some step previously failed, so mark the build as failed right away.
        tracing::warn!(
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
            .get_last_build_step_id(&self.store.print_store_path(step.get_drv_path()))
            .await?
            .unwrap_or_default();

        if propagated_from == 0 {
            // we can access step.drv here because the value is always set if
            // PreviousFailure is returned, so this should never yield None

            let outputs = step.get_outputs().unwrap_or_default();
            for o in outputs {
                let res = if let Some(path) = &o.path {
                    tx.get_last_build_step_id_for_output_path(&self.store.print_store_path(path))
                        .await
                } else {
                    tx.get_last_build_step_id_for_output_with_drv(
                        &self.store.print_store_path(step.get_drv_path()),
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
            &self.store.print_store_path(step.get_drv_path()),
            step.get_system().as_deref(),
            String::new(),
            BuildStatus::CachedFailure,
            None,
            Some(propagated_from),
            step.get_outputs()
                .unwrap_or_default()
                .into_iter()
                .map(|o| (o.name, o.path.map(|s| self.store.print_store_path(&s))))
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
        self.metrics.nr_builds_done.inc();
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
        new_builds_by_id: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: &HashMap<nix_utils::StorePath, HashSet<BuildID>>,
        finished_drvs: Arc<parking_lot::RwLock<HashSet<nix_utils::StorePath>>>,
        new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
    ) {
        self.metrics.queue_build_loads.inc();
        tracing::info!("loading build {} ({})", build.id, build.full_job_name());
        nr_added.fetch_add(1, Ordering::Relaxed);
        {
            let mut new_builds_by_id = new_builds_by_id.write();
            new_builds_by_id.remove(&build.id);
        }

        if !self.store.is_valid_path(&build.drv_path).await {
            tracing::error!("aborting GC'ed build {}", build.id);
            if !build.get_finished_in_db() {
                match self.db.get().await {
                    Ok(mut conn) => {
                        if let Err(e) = conn.abort_build(build.id).await {
                            tracing::error!("Failed to abort the build={} e={}", build.id, e);
                        }
                    }
                    Err(e) => tracing::error!(
                        "Failed to get database connection so we can abort the build={} e={}",
                        build.id,
                        e
                    ),
                }
            }

            build.set_finished_in_db(true);
            self.metrics.nr_builds_done.inc();
            return;
        }

        // Create steps for this derivation and its dependencies.
        let new_steps = Arc::new(parking_lot::RwLock::new(HashSet::<Arc<Step>>::new()));
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
                    tracing::error!("Failed to handle previous failure: {e}");
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
                        if let Some(j) = new_builds_by_id.read().get(&b) {
                            j.clone()
                        } else {
                            return;
                        }
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
                self.builds.insert_new_build(build.clone());
            }

            build.set_toplevel_step(step.clone());
            build.propagate_priorities();

            tracing::info!(
                "added build {} (top-level step {}, {} new steps)",
                build.id,
                step.get_drv_path(),
                new_steps.read().len()
            );
        } else {
            // If we didn't get a step, it means the step's outputs are
            // all valid. So we mark this as a finished, cached build.
            if let Err(e) = self.handle_cached_build(build).await {
                tracing::error!("failed to handle cached build: {e}");
            }
        }
    }

    #[allow(clippy::too_many_lines, clippy::too_many_arguments)]
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
        finished_drvs: Arc<parking_lot::RwLock<HashSet<nix_utils::StorePath>>>,
        new_steps: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
        new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
    ) -> CreateStepResult {
        use futures::stream::StreamExt as _;

        {
            let finished_drvs = finished_drvs.read();
            if finished_drvs.contains(&drv_path) {
                return CreateStepResult::None;
            }
        }

        let (step, is_new) =
            self.steps
                .create(&drv_path, referring_build.as_ref(), referring_step.as_ref());
        if !is_new {
            return CreateStepResult::Valid(step);
        }
        self.metrics.queue_steps_created.inc();
        tracing::debug!("considering derivation '{drv_path}'");

        let Some(drv) = nix_utils::query_drv(&self.store, &drv_path)
            .await
            .ok()
            .flatten()
        else {
            return CreateStepResult::None;
        };
        if let Some(fod_checker) = &self.fod_checker {
            fod_checker.add_ca_drv_parsed(&drv_path, &drv);
        }

        let system_type = drv.system.as_str();
        #[allow(clippy::cast_precision_loss)]
        self.metrics
            .observe_build_input_drvs(drv.input_drvs.len() as f64, system_type);

        let use_substitutes = self.config.get_use_substitutes();
        // TODO: check all remote stores
        let remote_store = {
            let r = self.remote_stores.read();
            r.first().cloned()
        };
        let missing_outputs = if let Some(ref remote_store) = remote_store {
            let mut missing = remote_store
                .query_missing_remote_outputs(drv.outputs.to_vec())
                .await;
            if !missing.is_empty()
                && self
                    .store
                    .query_missing_outputs(drv.outputs.to_vec())
                    .await
                    .is_empty()
            {
                // we have all paths locally, so we can just upload them to the remote_store
                if let Ok(log_file) = self.construct_log_file_path(&drv_path).await {
                    let missing_paths: Vec<nix_utils::StorePath> =
                        missing.iter().filter_map(|v| v.path.clone()).collect();
                    if let Err(e) = self.uploader.schedule_upload(
                        missing_paths,
                        format!("log/{}", drv_path.base_name()),
                        log_file.to_string_lossy().to_string(),
                    ) {
                        tracing::error!("Failed to schedule upload for derivation {drv_path}: {e}");
                    } else {
                        missing.clear();
                    }
                }
            }
            missing
        } else {
            self.store.query_missing_outputs(drv.outputs.to_vec()).await
        };

        step.set_drv(drv);

        if self.check_cached_failure(step.clone()).await {
            step.set_previous_failure(true);
            return CreateStepResult::PreviousFailure(step);
        }

        tracing::debug!("missing outputs: {missing_outputs:?}");
        let finished = if !missing_outputs.is_empty() && use_substitutes {
            use futures::stream::StreamExt as _;

            let mut substituted = 0;
            let missing_outputs_len = missing_outputs.len();

            let mut stream = futures::StreamExt::map(tokio_stream::iter(missing_outputs), |o| {
                self.metrics.nr_substitutes_started.inc();
                crate::utils::substitute_output(
                    self.db.clone(),
                    self.store.clone(),
                    o,
                    build.id,
                    &drv_path,
                    remote_store.as_ref(),
                )
            })
            .buffer_unordered(10);
            while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
                match v {
                    Ok(v) if v => {
                        self.metrics.nr_substitutes_succeeded.inc();
                        substituted += 1;
                    }
                    Ok(_) => {
                        self.metrics.nr_substitutes_failed.inc();
                    }
                    Err(e) => {
                        self.metrics.nr_substitutes_failed.inc();
                        tracing::warn!("Failed to substitute path: {e}");
                    }
                }
            }
            substituted == missing_outputs_len
        } else {
            missing_outputs.is_empty()
        };

        if finished {
            if let Some(fod_checker) = &self.fod_checker {
                fod_checker.to_traverse(&drv_path);
            }

            finished_drvs.write().insert(drv_path.clone());
            step.set_finished(true);
            return CreateStepResult::None;
        }

        tracing::debug!("creating build step '{drv_path}");
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
                        step.add_dep(dep);
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
                .filter_map(|o| o.path.as_ref().map(|p| self.store.print_store_path(p)))
                .collect::<Vec<_>>(),
        )
        .await
        .unwrap_or_default()
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

            tracing::info!("marking build {} as succeeded (cached)", build.id);
            let now = jiff::Timestamp::now().as_second();
            tx.mark_succeeded_build(
                get_mark_build_sccuess_data(&self.store, &build, &res),
                true,
                i32::try_from(now)?, // TODO
                i32::try_from(now)?, // TODO
            )
            .await?;
            self.metrics.nr_builds_done.inc();

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
        let drv = nix_utils::query_drv(&self.store, drv_path)
            .await?
            .ok_or_else(|| anyhow::anyhow!("Derivation not found"))?;

        {
            let mut db = self.db.get().await?;
            for o in &drv.outputs {
                let Some(out_path) = &o.path else {
                    continue;
                };
                let Some(db_build_output) = db
                    .get_build_output_for_path(&self.store.print_store_path(out_path))
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

        let build_output = BuildOutput::new(&self.store, drv.outputs.to_vec()).await?;

        #[allow(clippy::cast_precision_loss)]
        self.metrics
            .observe_build_closure_size(build_output.closure_size as f64, &drv.system);

        Ok(build_output)
    }

    fn add_root(&self, drv_path: &nix_utils::StorePath) {
        let roots_dir = self.config.get_roots_dir();
        nix_utils::add_root(&self.store, &roots_dir, drv_path);
    }

    async fn abort_unsupported(&self) {
        let runnable = self.steps.clone_runnable();
        let now = jiff::Timestamp::now();

        let mut aborted = HashSet::new();
        let mut count = 0;

        let max_unsupported_time = self.config.get_max_unsupported_time();
        for step in &runnable {
            let supported = self.machines.support_step(step);
            if supported {
                step.set_last_supported_now();
                continue;
            }

            count += 1;
            if (now - step.get_last_supported())
                .total(jiff::Unit::Second)
                .unwrap_or_default()
                < max_unsupported_time.as_secs_f64()
            {
                continue;
            }

            let drv = step.get_drv_path();
            let system = step.get_system();
            tracing::error!("aborting unsupported build step '{drv}' (type '{system:?}')",);

            aborted.insert(step.clone());

            let mut dependents = HashSet::new();
            let mut steps = HashSet::new();
            step.get_dependents(&mut dependents, &mut steps);
            // Maybe the step got cancelled.
            if dependents.is_empty() {
                continue;
            }

            // Find the build that has this step as the top-level (if any).
            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or_else(|| dependents.iter().next())
            else {
                // this should never happen, as we checked is_empty above and fallback is just any build
                continue;
            };

            let mut job = machine::Job::new(build.id, drv.to_owned(), None);
            job.result.set_start_and_stop(now);
            job.result.step_status = BuildStatus::Unsupported;
            job.result.error_msg = Some(format!(
                "unsupported system type '{}'",
                system.unwrap_or(String::new())
            ));
            if let Err(e) = self.inner_fail_job(drv, None, job, step.clone()).await {
                tracing::error!("Failed to fail step drv={drv} e={e}");
            }
        }

        {
            for step in &aborted {
                self.queues.remove_job_by_path(step.get_drv_path()).await;
            }
            self.queues.remove_all_weak_pointer().await;
        }
        self.metrics.nr_unsupported_steps.set(count);
        self.metrics
            .nr_unsupported_steps_aborted
            .inc_by(aborted.len() as u64);
    }
}
