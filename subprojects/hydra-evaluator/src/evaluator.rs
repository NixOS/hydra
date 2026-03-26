use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context as _;
use futures::StreamExt as _;
use tokio::process::Command;
use tokio::sync::{Mutex, Notify};

use crate::config::HydraConfig;

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
    last_checked_time: i64,
    trigger_time: Option<i64>,
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
    jobsets: BTreeMap<i32, Jobset>,
}

pub(crate) struct Evaluator {
    db: db::Database,
    max_evals: usize,
    eval_one: Option<(String, String)>,
    state: Arc<Mutex<State>>,
    notify_work: Arc<Notify>,
}

impl Evaluator {
    pub(crate) fn new(
        db: db::Database,
        config: &HydraConfig,
        eval_one: Option<(String, String)>,
    ) -> Self {
        let max_evals = config.get_int("max_concurrent_evals", 4).max(1) as usize;
        Self {
            db,
            max_evals,
            eval_one,
            state: Arc::new(Mutex::new(State::default())),
            notify_work: Arc::new(Notify::new()),
        }
    }

    pub(crate) async fn run(self) -> anyhow::Result<()> {
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

        let mut sigint =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
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
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        }
    }

    async fn main_loop_iteration(&self) -> anyhow::Result<()> {
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

        if sleep_secs == i64::MAX {
            Duration::MAX
        } else {
            Duration::from_secs(sleep_secs as u64)
        }
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

    async fn db_monitor_loop(&self) -> anyhow::Result<()> {
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
                    tracing::info!("received jobset event");
                    self.read_jobsets().await?;
                    self.notify_work.notify_one();
                }
                Some(Err(e)) => {
                    return Err(e.into());
                }
                None => {
                    anyhow::bail!("notification stream ended");
                }
            }
        }
    }

    async fn read_jobsets(&self) -> anyhow::Result<()> {
        let rows = sqlx::query_as::<_, JobsetRow>(
            "SELECT j.id, project, j.name, \
             lastCheckedTime, triggerTime, checkInterval, \
             j.enabled as jobset_enabled \
             FROM Jobsets j \
             JOIN Projects p ON j.project = p.name \
             WHERE j.enabled != 0 AND p.enabled != 0",
        )
        .fetch_all(self.db.pool())
        .await?;

        let mut state = self.state.lock().await;
        let mut seen = HashSet::new();

        for row in &rows {
            if let Some((ref proj, ref js)) = self.eval_one {
                if row.project != *proj || row.name != *js {
                    continue;
                }
            }

            seen.insert(row.id);

            let evaluation_style = EvaluationStyle::from_i32(row.jobset_enabled);

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

        state.jobsets.retain(|id, jobset| {
            if seen.contains(id) {
                true
            } else {
                tracing::info!("forgetting jobset '{}'", jobset.display());
                false
            }
        });

        Ok(())
    }

    async fn should_evaluate(&self, jobset: &Jobset, state: &State) -> bool {
        if state.running_ids.contains(&jobset.id) {
            tracing::debug!(
                "shouldEvaluate {}? no: already running",
                jobset.display()
            );
            return false;
        }

        if jobset.trigger_time.is_some() {
            tracing::debug!(
                "shouldEvaluate {}? yes: requested",
                jobset.display()
            );
            return true;
        }

        if jobset.check_interval <= 0 {
            tracing::debug!(
                "shouldEvaluate {}? no: checkInterval <= 0",
                jobset.display()
            );
            return false;
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
            return true;
        }

        false
    }

    async fn should_evaluate_one_at_a_time(&self, jobset: &Jobset) -> bool {
        let eval_id: Option<i32> = match sqlx::query_scalar(
            "SELECT id FROM JobsetEvals WHERE jobset_id = $1 ORDER BY id DESC LIMIT 1",
        )
        .bind(jobset.id)
        .fetch_optional(self.db.pool())
        .await
        {
            Ok(v) => v,
            Err(e) => {
                tracing::error!(
                    "error checking one-at-a-time for {}: {e}",
                    jobset.display()
                );
                return false;
            }
        };

        let Some(eval_id) = eval_id else {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? yes: no prior eval",
                jobset.display()
            );
            return true;
        };

        let unfinished: Option<i32> = match sqlx::query_scalar(
            "SELECT id FROM Builds \
             JOIN JobsetEvalMembers ON (JobsetEvalMembers.build = Builds.id) \
             WHERE JobsetEvalMembers.eval = $1 AND builds.finished = 0 \
             LIMIT 1",
        )
        .bind(eval_id)
        .fetch_optional(self.db.pool())
        .await
        {
            Ok(v) => v,
            Err(e) => {
                tracing::error!(
                    "error checking unfinished builds for {}: {e}",
                    jobset.display()
                );
                return false;
            }
        };

        if unfinished.is_none() {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? yes: no unfinished builds",
                jobset.display()
            );
            true
        } else {
            tracing::debug!(
                "shouldEvaluate(one-at-a-time) {}? no: at least one unfinished build",
                jobset.display()
            );
            false
        }
    }

    async fn start_evals(&self, state: &mut State) -> anyhow::Result<()> {
        // Collect eligible jobset IDs with their sort keys
        let mut candidates: Vec<(i32, Option<i64>, i64)> = Vec::new();

        for jobset in state.jobsets.values() {
            if self.eval_one.is_some() || (jobset.evaluation_style.is_some() && self.should_evaluate(jobset, state).await) {
                candidates.push((
                    jobset.id,
                    jobset.trigger_time,
                    jobset.last_checked_time,
                ));
            }
        }

        // Sort by (trigger_time, last_checked_time, id)
        // None trigger_time sorts after Some (not triggered = lowest priority)
        candidates.sort_by(|a, b| {
            let ta = a.1.unwrap_or(i64::MAX);
            let tb = b.1.unwrap_or(i64::MAX);
            ta.cmp(&tb)
                .then(a.2.cmp(&b.2))
                .then(a.0.cmp(&b.0))
        });

        for (jobset_id, _, _) in candidates {
            if state.running_evals >= self.max_evals {
                break;
            }
            // Re-borrow the jobset from state
            if let Some(jobset) = state.jobsets.get(&jobset_id) {
                self.start_eval(state, jobset_id, jobset.project.clone(), jobset.name.clone())
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
    ) -> anyhow::Result<()> {
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

        sqlx::query("UPDATE Jobsets SET startTime = $1 WHERE id = $2")
            .bind(now as i32)
            .bind(jobset_id)
            .execute(self.db.pool())
            .await
            .context("failed to set startTime")?;

        let child = Command::new("hydra-eval-jobset")
            .arg(&project)
            .arg(&jobset_name)
            .spawn()
            .with_context(|| format!("failed to spawn hydra-eval-jobset for {jobset_display}"))?;

        state.running_evals += 1;
        state.running_ids.insert(jobset_id);

        let eval_one = self.eval_one.is_some();
        let db = self.db.clone();
        let state_arc = Arc::clone(&self.state);
        let notify_work = Arc::clone(&self.notify_work);

        tokio::spawn(async move {
            reap_child(child, jobset_id, jobset_display, eval_one, db, state_arc, notify_work).await;
        });

        Ok(())
    }

    async fn unlock(&self) -> anyhow::Result<()> {
        sqlx::query("UPDATE Jobsets SET startTime = null")
            .execute(self.db.pool())
            .await
            .context("failed to unlock jobsets")?;
        Ok(())
    }
}

async fn reap_child(
    mut child: tokio::process::Child,
    jobset_id: i32,
    jobset_display: String,
    eval_one: bool,
    db: db::Database,
    state: Arc<Mutex<State>>,
    notify_work: Arc<Notify>,
) {
    let status = child.wait().await;

    let (exit_ok, status_str) = match &status {
        Ok(s) => {
            let code = s.code();
            let ok = code == Some(0) || code == Some(1);
            (ok, format!("{s}"))
        }
        Err(e) => (false, format!("error: {e}")),
    };

    tracing::info!("evaluation of jobset '{}' {}", jobset_display, status_str);

    let now = now_epoch();

    {
        let mut st = state.lock().await;
        if st.running_evals > 0 {
            st.running_evals -= 1;
        }
        st.running_ids.remove(&jobset_id);

        if let Some(jobset) = st.jobsets.get_mut(&jobset_id) {
            jobset.trigger_time = None;
            jobset.last_checked_time = now;
        }
    }

    if let Err(e) = update_db_after_eval(&db, jobset_id, exit_ok, &status_str, now).await {
        tracing::error!("exception setting jobset error: {e:#}");
    }

    notify_work.notify_one();

    if eval_one {
        std::process::exit(0);
    }
}

async fn update_db_after_eval(
    db: &db::Database,
    jobset_id: i32,
    exit_ok: bool,
    status_str: &str,
    now: i64,
) -> anyhow::Result<()> {
    let pool = db.pool();

    // Clear trigger time to prevent stuck eval loop
    sqlx::query(
        "UPDATE Jobsets SET triggerTime = null \
         WHERE id = $1 AND startTime IS NOT NULL AND triggerTime <= startTime",
    )
    .bind(jobset_id)
    .execute(pool)
    .await?;

    // Clear start time
    sqlx::query("UPDATE Jobsets SET startTime = null WHERE id = $1")
        .bind(jobset_id)
        .execute(pool)
        .await?;

    if !exit_ok {
        sqlx::query(
            "UPDATE Jobsets SET errorMsg = $1, lastCheckedTime = $2, \
             errorTime = $2, fetchErrorMsg = null WHERE id = $3",
        )
        .bind(format!("evaluation {status_str}"))
        .bind(now as i32)
        .bind(jobset_id)
        .execute(pool)
        .await?;
    }

    Ok(())
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn is_broken_connection(e: &anyhow::Error) -> bool {
    for cause in e.chain() {
        if let Some(sqlx_err) = cause.downcast_ref::<sqlx::Error>() {
            if matches!(sqlx_err, sqlx::Error::Io(_) | sqlx::Error::PoolClosed) {
                return true;
            }
        }
    }
    false
}

#[derive(sqlx::FromRow)]
#[allow(non_snake_case)]
struct JobsetRow {
    id: i32,
    project: String,
    name: String,
    lastcheckedtime: Option<i64>,
    triggertime: Option<i64>,
    checkinterval: i32,
    jobset_enabled: i32,
}
