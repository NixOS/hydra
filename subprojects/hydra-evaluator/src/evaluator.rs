use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{self, WrapErr as _};
use futures::{FutureExt as _, StreamExt as _};
use tokio::sync::{Mutex, Notify};

use crate::config::HydraConfig;
use crate::queries;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
enum EvaluationStyle {
    Schedule = 1,
    Oneshot = 2,
    OneAtATime = 3,
}

impl EvaluationStyle {
    fn from_i32(v: i32) -> Option<Self> {
        match v {
            1 => Some(Self::Schedule),
            2 => Some(Self::Oneshot),
            3 => Some(Self::OneAtATime),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct Jobset {
    id: i32,
    project: String,
    name: String,
    evaluation_style: Option<EvaluationStyle>,
    last_checked_time: db::Timestamp,
    trigger_time: Option<db::Timestamp>,
    check_interval: i64,
}

impl Jobset {
    fn display(&self) -> String {
        format!("{}:{} (jobset#{})", self.project, self.name, self.id)
    }
}

#[derive(Debug, Default)]
struct State {
    running_evals: usize,
    running_ids: HashSet<i32>,
    /// Kill switches for in-flight evals, so that forgetting a jobset
    /// (disabled/deleted while evaluating) can terminate its child, as
    /// the C++ version did via the `Pid` destructor.
    kill_evals: HashMap<i32, tokio::sync::oneshot::Sender<()>>,
    jobsets: BTreeMap<i32, Jobset>,
}

pub(crate) struct Evaluator {
    db: db::Database,
    /// Kept because evaluating is done here now, rather than by a program
    /// spawned per jobset that would read the configuration itself.
    config: Arc<HydraConfig>,
    available: Arc<crate::store_paths::Availability>,
    max_evals: usize,
    eval_one: Option<(String, String)>,
    state: Arc<Mutex<State>>,
    notify_work: Arc<Notify>,
}

impl Evaluator {
    pub(crate) fn new(
        db: db::Database,
        config: Arc<HydraConfig>,
        available: Arc<crate::store_paths::Availability>,
        eval_one: Option<(String, String)>,
    ) -> Self {
        let max_evals = config.max_concurrent_evals();
        Self {
            db,
            config,
            available,
            max_evals,
            eval_one,
            state: Arc::new(Mutex::new(State::default())),
            notify_work: Arc::new(Notify::new()),
        }
    }

    pub(crate) async fn run(self) -> eyre::Result<()> {
        self.unlock().await?;

        let this = Arc::new(self);

        let monitor = {
            let this = Arc::clone(&this);
            tokio::spawn(async move {
                this.db_monitor_task().await;
            })
        };

        let main_loop = {
            let this = Arc::clone(&this);
            tokio::spawn(async move {
                this.main_loop_task().await;
            })
        };

        let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
        let mut sigterm =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

        tokio::select! {
            _ = sigint.recv() => {
                tracing::info!("received SIGINT, exiting");
                std::process::exit(1);
            }
            _ = sigterm.recv() => {
                tracing::info!("received SIGTERM, exiting");
                std::process::exit(1);
            }
            _ = monitor => {
                tracing::error!("database monitor exited unexpectedly");
                std::process::exit(1);
            }
            _ = main_loop => {
                tracing::error!("main loop exited unexpectedly");
                std::process::exit(1);
            }
        }
    }

    async fn main_loop_task(&self) {
        loop {
            if let Err(e) = self.main_loop_iteration().await {
                tracing::error!("exception in main loop: {e:#}");
                if is_broken_connection(&e) {
                    tracing::error!("database connection broken, exiting");
                    std::process::exit(1);
                }
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        }
    }

    async fn main_loop_iteration(&self) -> eyre::Result<()> {
        loop {
            let sleep_duration = {
                let state = self.state.lock().await;
                self.compute_sleep_duration(&state)
            };

            tracing::debug!("waiting for {} s", sleep_duration.as_secs());

            if sleep_duration == Duration::MAX {
                self.notify_work.notified().await;
            } else {
                tokio::select! {
                    () = tokio::time::sleep(sleep_duration) => {}
                    () = self.notify_work.notified() => {}
                }
            }

            let mut state = self.state.lock().await;
            self.start_evals(&mut state).await?;
        }
    }

    fn compute_sleep_duration(&self, state: &State) -> Duration {
        if state.running_evals >= self.max_evals {
            return Duration::MAX;
        }

        let now = now_epoch();
        let mut sleep_secs = i64::MAX;

        for jobset in state.jobsets.values() {
            if state.running_ids.contains(&jobset.id) {
                continue;
            }
            if jobset.check_interval > 0 {
                let next = jobset.last_checked_time + jobset.check_interval - now;
                sleep_secs = sleep_secs.min(next.max(1));
            }
        }

        u64::try_from(sleep_secs).map_or(Duration::MAX, Duration::from_secs)
    }

    async fn db_monitor_task(&self) {
        loop {
            if let Err(e) = self.db_monitor_loop().await {
                tracing::error!("exception in database monitor: {e:#}");
                if is_broken_connection(&e) {
                    tracing::error!("database connection broken, exiting");
                    std::process::exit(1);
                }
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        }
    }

    async fn db_monitor_loop(&self) -> eyre::Result<()> {
        let mut stream = self
            .db
            .listener(vec![
                "jobsets_added",
                "jobsets_deleted",
                "jobset_scheduling_changed",
            ])
            .await?;

        // Read initial state before waiting for notifications
        self.read_jobsets().await?;
        self.notify_work.notify_one();

        loop {
            match stream.next().await {
                Some(Ok(_notification)) => {
                    // Drain any already-buffered notifications so a burst
                    // (e.g. a webhook triggering many jobsets) coalesces
                    // into a single re-read, as pqxx's await_notification
                    // did in the C++ version.
                    loop {
                        match stream.next().now_or_never() {
                            Some(Some(Ok(_))) => {}
                            Some(Some(Err(e))) => return Err(e.into()),
                            Some(None) => eyre::bail!("notification stream ended"),
                            None => break,
                        }
                    }
                    tracing::info!("received jobset event");
                    self.read_jobsets().await?;
                    self.notify_work.notify_one();
                }
                Some(Err(e)) => {
                    return Err(e.into());
                }
                None => {
                    eyre::bail!("notification stream ended");
                }
            }
        }
    }

    async fn read_jobsets(&self) -> eyre::Result<()> {
        let rows = queries::get_schedulable_jobsets(&mut self.db.get().await?).await?;

        let mut state = self.state.lock().await;
        let mut seen = HashSet::new();

        for row in &rows {
            if let Some((ref proj, ref js)) = self.eval_one
                && (row.project != *proj || row.name != *js)
            {
                continue;
            }

            seen.insert(row.id);

            let evaluation_style = EvaluationStyle::from_i32(row.enabled);

            let jobset = state.jobsets.entry(row.id).or_insert_with(|| Jobset {
                id: row.id,
                project: row.project.clone(),
                name: row.name.clone(),
                evaluation_style: None,
                last_checked_time: 0,
                trigger_time: None,
                check_interval: 0,
            });

            jobset.project.clone_from(&row.project);
            jobset.name.clone_from(&row.name);
            jobset.last_checked_time = row.lastcheckedtime.unwrap_or(0);
            jobset.trigger_time = row.triggertime;
            jobset.check_interval = row.checkinterval.into();
            jobset.evaluation_style = evaluation_style;
        }

        if self.eval_one.is_some() && seen.is_empty() {
            tracing::error!("the specified jobset does not exist or is disabled");
            std::process::exit(1);
        }

        let forgotten: Vec<i32> = state
            .jobsets
            .keys()
            .filter(|id| !seen.contains(id))
            .copied()
            .collect();
        for id in forgotten {
            if let Some(jobset) = state.jobsets.remove(&id) {
                tracing::info!("forgetting jobset '{}'", jobset.display());
            }
            // Kill any in-flight eval, as the C++ version did when
            // erasing a jobset (the Pid destructor SIGKILLed the child).
            if let Some(kill) = state.kill_evals.remove(&id) {
                let _ = kill.send(());
            }
        }

        Ok(())
    }

    async fn should_evaluate(&self, jobset: &Jobset, state: &State) -> eyre::Result<bool> {
        if state.running_ids.contains(&jobset.id) {
            tracing::debug!("shouldEvaluate {}? no: already running", jobset.display());
            return Ok(false);
        }

        if jobset.trigger_time.is_some() {
            tracing::debug!("shouldEvaluate {}? yes: requested", jobset.display());
            return Ok(true);
        }

        if jobset.check_interval <= 0 {
            tracing::debug!(
                "shouldEvaluate {}? no: checkInterval <= 0",
                jobset.display()
            );
            return Ok(false);
        }

        let now = now_epoch();
        if jobset.last_checked_time + jobset.check_interval <= now {
            if jobset.evaluation_style == Some(EvaluationStyle::OneAtATime) {
                return self.should_evaluate_one_at_a_time(jobset).await;
            }
            tracing::debug!(
                "shouldEvaluate(oneshot/scheduled) {}? yes: checkInterval elapsed",
                jobset.display()
            );
            return Ok(true);
        }

        Ok(false)
    }

    // Errors propagate to the main loop (30 s backoff, exit on broken
    // connection) rather than being swallowed here, which would retry
    // the failing query every second via the sleep clamp.
    async fn should_evaluate_one_at_a_time(&self, jobset: &Jobset) -> eyre::Result<bool> {
        let mut conn = self.db.get().await?;

        let eval_id = queries::get_latest_eval_id(&mut conn, jobset.id)
            .await
            .wrap_err_with(|| format!("checking one-at-a-time for {}", jobset.display()))?;

        let Some(eval_id) = eval_id else {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? yes: no prior eval",
                jobset.display()
            );
            return Ok(true);
        };

        let unfinished = queries::eval_has_unfinished_builds(&mut conn, eval_id)
            .await
            .wrap_err_with(|| format!("checking unfinished builds for {}", jobset.display()))?;

        if unfinished {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? no: at least one unfinished build",
                jobset.display()
            );
            Ok(false)
        } else {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? yes: no unfinished builds",
                jobset.display()
            );
            Ok(true)
        }
    }

    async fn start_evals(&self, state: &mut State) -> eyre::Result<()> {
        // Collect eligible jobset IDs with their sort keys
        let mut candidates: Vec<(i32, Option<db::Timestamp>, db::Timestamp)> = Vec::new();

        for jobset in state.jobsets.values() {
            // Checked here as well as in should_evaluate so that eval-one
            // mode (which bypasses should_evaluate) cannot start a second
            // concurrent eval of its jobset on a mid-eval wakeup.
            if state.running_ids.contains(&jobset.id) {
                continue;
            }
            if self.eval_one.is_some()
                || (jobset.evaluation_style.is_some()
                    && self.should_evaluate(jobset, state).await?)
            {
                candidates.push((jobset.id, jobset.trigger_time, jobset.last_checked_time));
            }
        }

        // Sort by (trigger_time, last_checked_time, id)
        // None trigger_time sorts after Some (not triggered = lowest priority)
        candidates.sort_by(|a, b| {
            let ta = a.1.unwrap_or(i64::MAX);
            let tb = b.1.unwrap_or(i64::MAX);
            ta.cmp(&tb).then(a.2.cmp(&b.2)).then(a.0.cmp(&b.0))
        });

        for (jobset_id, _, _) in candidates {
            if state.running_evals >= self.max_evals {
                break;
            }
            // Re-borrow the jobset from state
            if let Some(jobset) = state.jobsets.get(&jobset_id) {
                self.start_eval(
                    state,
                    jobset_id,
                    jobset.project.clone(),
                    jobset.name.clone(),
                )
                .await?;
            }
        }

        Ok(())
    }

    async fn start_eval(
        &self,
        state: &mut State,
        jobset_id: i32,
        project: String,
        jobset_name: String,
    ) -> eyre::Result<()> {
        let now = now_epoch();
        let jobset_display = format!("{project}:{jobset_name} (jobset#{jobset_id})");

        let last_checked = state
            .jobsets
            .get(&jobset_id)
            .map_or(0, |j| j.last_checked_time);

        tracing::info!(
            "starting evaluation of jobset '{}' (last checked {} s ago)",
            jobset_display,
            now - last_checked,
        );

        queries::set_jobset_start_time(&mut self.db.get().await?, jobset_id, now)
            .await
            .wrap_err("failed to set startTime")?;

        let (kill_tx, kill_rx) = tokio::sync::oneshot::channel();
        state.running_evals += 1;
        state.running_ids.insert(jobset_id);
        state.kill_evals.insert(jobset_id, kill_tx);

        let eval_one = self.eval_one.is_some();
        let db = self.db.clone();
        let state_arc = Arc::clone(&self.state);
        let notify_work = Arc::clone(&self.notify_work);

        let config = Arc::clone(&self.config);
        let available = Arc::clone(&self.available);
        let trace = format!("{now}.{jobset_id}");
        let reap_trace = trace.clone();

        let eval_db = db.clone();

        tokio::spawn(async move {
            // Built inside the task so the future owns what it borrows; it
            // outlives this scope by design.
            let evaluation = Box::pin(async move {
                crate::evaluate::evaluate(
                    &eval_db,
                    &config,
                    &available,
                    &project,
                    &jobset_name,
                    &trace,
                )
                .await
            });

            reap_eval(
                evaluation,
                kill_rx,
                jobset_id,
                reap_trace,
                jobset_display,
                now,
                eval_one,
                db,
                state_arc,
                notify_work,
            )
            .await;
        });

        Ok(())
    }

    async fn unlock(&self) -> eyre::Result<()> {
        queries::unlock_all_jobsets(&mut self.db.get().await?)
            .await
            .wrap_err("failed to unlock jobsets")?;
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
async fn reap_eval(
    evaluation: std::pin::Pin<
        Box<dyn Future<Output = eyre::Result<crate::evaluate::Outcome>> + Send>,
    >,
    mut kill_rx: tokio::sync::oneshot::Receiver<()>,
    jobset_id: i32,
    trace: String,
    jobset_display: String,
    start_time: db::Timestamp,
    eval_one: bool,
    db: db::Database,
    state: Arc<Mutex<State>>,
    notify_work: Arc<Notify>,
) {
    // Abandoning the future is how an evaluation is cancelled now that it is
    // not a process: dropping it stops the work, and anything it had already
    // committed stands, as it would have with a killed child.
    let outcome = tokio::select! {
        result = evaluation => Some(result),
        _ = &mut kill_rx => {
            tracing::info!("abandoning evaluation of jobset '{jobset_display}'");
            None
        }
    };

    let (exit_ok, status_str) = match &outcome {
        Some(Ok(crate::evaluate::Outcome::Cached { previous })) => {
            (true, format!("cached, same as evaluation {previous}"))
        }
        Some(Ok(crate::evaluate::Outcome::Evaluated { eval, changed })) => (
            true,
            if *changed {
                format!("added evaluation {eval}")
            } else {
                format!("evaluation {eval} found no changes")
            },
        ),
        Some(Err(e)) => (false, format!("{e:#}")),
        None => (true, "abandoned".to_owned()),
    };

    tracing::info!("evaluation of jobset '{}' {}", jobset_display, status_str);

    let now = now_epoch();

    let mut st = state.lock().await;
    let exit_ok = if let Some(jobset) = st.jobsets.get_mut(&jobset_id) {
        // A trigger that arrived while the eval was running is kept in the
        // database (see update_jobset_after_eval); keep it in memory too so
        // the jobset is re-evaluated without waiting for another NOTIFY.
        if jobset.trigger_time.is_some_and(|t| t <= start_time) {
            jobset.trigger_time = None;
        }
        jobset.last_checked_time = now;
        exit_ok
    } else {
        // The jobset was disabled or deleted mid-eval and its child
        // killed by read_jobsets; only clear startTime and do not record
        // the SIGKILL as an evaluation error.
        true
    };

    // Hold the lock across the DB cleanup and only mark the jobset
    // not-running afterwards (as the C++ reaper did), so a new eval
    // of the same jobset cannot start in between and have its fresh
    // startTime clobbered by this transaction.
    if let Err(e) = update_db_after_eval(&db, &trace, jobset_id, exit_ok, &status_str, now).await {
        tracing::error!("exception setting jobset error: {e:#}");
    }

    if st.running_evals > 0 {
        st.running_evals -= 1;
    }
    st.running_ids.remove(&jobset_id);
    st.kill_evals.remove(&jobset_id);

    notify_work.notify_one();

    // Exit while still holding the lock: start_evals skips should_evaluate
    // in eval-one mode, so a woken main loop could otherwise start a second
    // eval of the jobset before the process is gone.
    if eval_one {
        // Non-zero when the evaluation failed: `hydra-evaluator p j` is how
        // a single evaluation is asked for, and its caller wants to know.
        std::process::exit(i32::from(!exit_ok));
    }
}

async fn update_db_after_eval(
    db: &db::Database,
    trace: &str,
    jobset_id: i32,
    exit_ok: bool,
    status_str: &str,
    now: db::Timestamp,
) -> eyre::Result<()> {
    let mut conn = db.get().await?;

    // A failure is announced; a success is not, because `record` already sent
    // `eval_added` -- carrying the same flag -- from inside the transaction
    // that produced the evaluation.
    if exit_ok {
        queries::update_jobset_after_eval(&mut conn, jobset_id, None, now).await?;
    } else {
        queries::fail_jobset_eval(
            &mut conn,
            trace,
            jobset_id,
            &format!("evaluation {status_str}"),
            now,
        )
        .await?;
    }
    Ok(())
}

fn now_epoch() -> db::Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_secs()).ok())
        .unwrap_or(0)
}

fn is_broken_connection(e: &eyre::Report) -> bool {
    fn broken(e: &sqlx::Error) -> bool {
        matches!(e, sqlx::Error::Io(_) | sqlx::Error::PoolClosed)
    }
    for cause in e.chain() {
        if let Some(sqlx_err) = cause.downcast_ref::<sqlx::Error>()
            && broken(sqlx_err)
        {
            return true;
        }
        // `db::Error::Sql` is `#[error(transparent)]`, so the inner
        // `sqlx::Error` never appears as its own element of the chain
        // and must be matched through the wrapper.
        if let Some(db::Error::Sql(sqlx_err)) = cause.downcast_ref::<db::Error>()
            && broken(sqlx_err)
        {
            return true;
        }
    }
    false
}
