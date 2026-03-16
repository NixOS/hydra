use std::sync::Arc;

use hashbrown::HashMap;

use super::{BuildQueueStats, Process};

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueRunnerStats {
    status: &'static str,
    time: jiff::Timestamp,
    uptime: f64,
    proc: Option<Process>,
    supported_features: Vec<String>,

    build_count: usize,
    jobset_count: usize,
    step_count: usize,
    runnable_count: usize,
    queue_stats: HashMap<crate::state::System, BuildQueueStats>,

    queue_checks_started: u64,
    queue_build_loads: u64,
    queue_steps_created: u64,
    queue_checks_early_exits: u64,
    queue_checks_finished: u64,

    dispatcher_time_spent_running: u64,
    dispatcher_time_spent_waiting: u64,

    queue_monitor_time_spent_running: u64,
    queue_monitor_time_spent_waiting: u64,

    nr_builds_read: u64,
    build_read_time_ms: u64,
    nr_builds_unfinished: i64,
    nr_builds_done: u64,
    nr_builds_succeeded: u64,
    nr_builds_failed: u64,
    nr_steps_started: u64,
    nr_steps_done: u64,
    nr_steps_building: i64,
    nr_steps_waiting: i64,
    nr_steps_runnable: i64,
    nr_steps_unfinished: i64,
    nr_unsupported_steps: i64,
    nr_unsupported_steps_aborted: u64,
    nr_substitutes_started: u64,
    nr_substitutes_failed: u64,
    nr_substitutes_succeeded: u64,
    nr_retries: u64,
    max_nr_retries: i64,
    avg_step_time_ms: i64,
    avg_step_import_time_ms: i64,
    avg_step_build_time_ms: i64,
    avg_step_upload_time_ms: i64,
    total_step_time_ms: u64,
    total_step_import_time_ms: u64,
    total_step_build_time_ms: u64,
    total_step_upload_time_ms: u64,
    nr_queue_wakeups: u64,
    nr_dispatcher_wakeups: u64,
    dispatch_time_ms: u64,
    machines_total: i64,
    machines_in_use: i64,
    s3_uploads_pending: i64,
}

impl QueueRunnerStats {
    pub async fn new(state: Arc<crate::state::State>) -> Self {
        let build_count = state.builds.len();
        let jobset_count = state.jobsets.len();
        let step_count = state.steps.len();
        let runnable_count = state.steps.len_runnable();
        let queue_stats = {
            state
                .queues
                .get_stats_per_queue()
                .await
                .into_iter()
                .map(|(system, stats)| (system, stats.into()))
                .collect()
        };

        state.metrics.refresh_dynamic_metrics(&state).await;

        let time = jiff::Timestamp::now();
        Self {
            status: "up",
            time,
            uptime: (time - state.started_at)
                .total(jiff::Unit::Second)
                .unwrap_or_default(),
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
            nr_builds_succeeded: state.metrics.nr_builds_succeeded.get(),
            nr_builds_failed: state.metrics.nr_builds_failed.get(),
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
            avg_step_upload_time_ms: state.metrics.avg_step_upload_time_ms.get(),
            total_step_time_ms: state.metrics.total_step_time_ms.get(),
            total_step_import_time_ms: state.metrics.total_step_import_time_ms.get(),
            total_step_build_time_ms: state.metrics.total_step_build_time_ms.get(),
            total_step_upload_time_ms: state.metrics.total_step_upload_time_ms.get(),
            nr_queue_wakeups: state.metrics.nr_queue_wakeups.get(),
            nr_dispatcher_wakeups: state.metrics.nr_dispatcher_wakeups.get(),
            dispatch_time_ms: state.metrics.dispatch_time_ms.get(),
            machines_total: state.metrics.machines_total.get(),
            machines_in_use: state.metrics.machines_in_use.get(),
            s3_uploads_pending: state.metrics.s3_uploads_pending.get(),
        }
    }
}
