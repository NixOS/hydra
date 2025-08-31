use std::sync::Arc;

use prometheus::Encoder as _;

use nix_utils::BaseStore as _;

#[derive(Debug)]
pub struct PromMetrics {
    pub queue_runner_current_time_seconds: prometheus::IntGauge, // hydraqueuerunner_current_time_seconds
    pub queue_runner_uptime_seconds: prometheus::IntGauge,       // hydraqueuerunner_uptime_seconds

    pub queue_checks_started: prometheus::IntCounter,
    pub queue_build_loads: prometheus::IntCounter,
    pub queue_steps_created: prometheus::IntCounter,
    pub queue_checks_early_exits: prometheus::IntCounter,
    pub queue_checks_finished: prometheus::IntCounter,

    pub dispatcher_time_spent_running: prometheus::IntCounter,
    pub dispatcher_time_spent_waiting: prometheus::IntCounter,

    pub queue_monitor_time_spent_running: prometheus::IntCounter,
    pub queue_monitor_time_spent_waiting: prometheus::IntCounter,

    pub nr_builds_read: prometheus::IntCounter, // hydraqueuerunner_builds_read
    pub build_read_time_ms: prometheus::IntCounter, // hydraqueuerunner_builds_read_time_ms
    pub nr_builds_unfinished: prometheus::IntGauge, // hydraqueuerunner_builds_unfinished
    pub nr_builds_done: prometheus::IntCounter, // hydraqueuerunner_builds_finished
    pub nr_builds_succeeded: prometheus::IntCounter, // hydraqueuerunner_builds_succeeded
    pub nr_builds_failed: prometheus::IntCounter, // hydraqueuerunner_builds_failed
    pub nr_steps_started: prometheus::IntCounter, // hydraqueuerunner_steps_started
    pub nr_steps_done: prometheus::IntCounter,  // hydraqueuerunner_steps_finished
    pub nr_steps_building: prometheus::IntGauge, // hydraqueuerunner_steps_building
    pub nr_steps_waiting: prometheus::IntGauge, // hydraqueuerunner_steps_waiting
    pub nr_steps_runnable: prometheus::IntGauge, // hydraqueuerunner_steps_runnable
    pub nr_steps_unfinished: prometheus::IntGauge, // hydraqueuerunner_steps_unfinished
    pub nr_unsupported_steps: prometheus::IntGauge, // hydraqueuerunner_steps_unsupported
    pub nr_unsupported_steps_aborted: prometheus::IntCounter, // hydraqueuerunner_steps_unsupported_aborted
    pub nr_substitutes_started: prometheus::IntCounter, // hydraqueuerunner_substitutes_started
    pub nr_substitutes_failed: prometheus::IntCounter,  // hydraqueuerunner_substitutes_failed
    pub nr_substitutes_succeeded: prometheus::IntCounter, // hydraqueuerunner_substitutes_succeeded
    pub nr_retries: prometheus::IntCounter,             // hydraqueuerunner_steps_retries
    pub max_nr_retries: prometheus::IntGauge,           // hydraqueuerunner_steps_max_retries
    pub nr_steps_copying_to: prometheus::IntGauge,      // hydraqueuerunner_steps_copying_to
    pub nr_steps_copying_from: prometheus::IntGauge,    // hydraqueuerunner_steps_copying_from
    pub avg_step_time_ms: prometheus::IntGauge,         // hydraqueuerunner_steps_avg_total_time_ms
    pub avg_step_import_time_ms: prometheus::IntGauge,  // hydraqueuerunner_steps_avg_import_time_ms
    pub avg_step_build_time_ms: prometheus::IntGauge,   // hydraqueuerunner_steps_avg_build_time_ms
    pub avg_step_upload_time_ms: prometheus::IntGauge,  // hydraqueuerunner_steps_avg_upload_time_ms
    pub total_step_time_ms: prometheus::IntCounter,     // hydraqueuerunner_steps_total_time_ms
    pub total_step_import_time_ms: prometheus::IntCounter, // hydraqueuerunner_steps_total_import_time_ms
    pub total_step_build_time_ms: prometheus::IntCounter, // hydraqueuerunner_steps_total_build_time_ms
    pub total_step_upload_time_ms: prometheus::IntCounter, // hydraqueuerunner_steps_total_upload_time_ms
    pub nr_queue_wakeups: prometheus::IntCounter,          //hydraqueuerunner_monitor_checks
    pub nr_dispatcher_wakeups: prometheus::IntCounter,     // hydraqueuerunner_dispatch_wakeup
    pub dispatch_time_ms: prometheus::IntCounter,          // hydraqueuerunner_dispatch_time_ms
    pub machines_total: prometheus::IntGauge,              // hydraqueuerunner_machines_total
    pub machines_in_use: prometheus::IntGauge,             // hydraqueuerunner_machines_in_use

    // Per-machine-type metrics
    pub runnable_per_machine_type: prometheus::IntGaugeVec, // hydraqueuerunner_machine_type_runnable
    pub running_per_machine_type: prometheus::IntGaugeVec,  // hydraqueuerunner_machine_type_running
    pub waiting_per_machine_type: prometheus::IntGaugeVec,  // hydraqueuerunner_machine_type_waiting
    pub disabled_per_machine_type: prometheus::IntGaugeVec, // hydraqueuerunner_machine_type_disabled
    pub avg_runnable_time_per_machine_type: prometheus::IntGaugeVec, // hydraqueuerunner_machine_type_avg_runnable_time
    pub wait_time_per_machine_type: prometheus::IntGaugeVec, // hydraqueuerunner_machine_type_wait_time

    // Per-machine metrics
    pub machine_current_jobs: prometheus::IntGaugeVec, // hydraqueuerunner_machine_current_jobs
    pub machine_steps_done: prometheus::IntGaugeVec,   // hydraqueuerunner_machine_steps_done
    pub machine_total_step_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_machine_total_step_time_ms
    pub machine_total_step_import_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_machine_total_step_import_time_ms
    pub machine_total_step_build_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_machine_total_step_build_time_ms
    pub machine_total_step_upload_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_machine_total_step_upload_time_ms
    pub machine_consecutive_failures: prometheus::IntGaugeVec, // hydraqueuerunner_machine_consecutive_failures
    pub machine_last_ping_timestamp: prometheus::IntGaugeVec, // hydraqueuerunner_machine_last_ping_timestamp
    pub machine_idle_since_timestamp: prometheus::IntGaugeVec, // hydraqueuerunner_machine_idle_since_timestamp

    // Store metrics (single store)
    pub store_nar_info_read: prometheus::IntGauge, // hydraqueuerunner_store_nar_info_read
    pub store_nar_info_read_averted: prometheus::IntGauge, // hydraqueuerunner_store_nar_info_read_averted
    pub store_nar_info_missing: prometheus::IntGauge, // hydraqueuerunner_store_nar_info_missing
    pub store_nar_info_write: prometheus::IntGauge,   // hydraqueuerunner_store_nar_info_write
    pub store_path_info_cache_size: prometheus::IntGauge, // hydraqueuerunner_store_path_info_cache_size
    pub store_nar_read: prometheus::IntGauge,             // hydraqueuerunner_store_nar_read
    pub store_nar_read_bytes: prometheus::IntGauge,       // hydraqueuerunner_store_nar_read_bytes
    pub store_nar_read_compressed_bytes: prometheus::IntGauge, // hydraqueuerunner_store_nar_read_compressed_bytes
    pub store_nar_write: prometheus::IntGauge,                 // hydraqueuerunner_store_nar_write
    pub store_nar_write_averted: prometheus::IntGauge, // hydraqueuerunner_store_nar_write_averted
    pub store_nar_write_bytes: prometheus::IntGauge,   // hydraqueuerunner_store_nar_write_bytes
    pub store_nar_write_compressed_bytes: prometheus::IntGauge, // hydraqueuerunner_store_nar_write_compressed_bytes
    pub store_nar_write_compression_time_ms: prometheus::IntGauge, // hydraqueuerunner_store_nar_write_compression_time_ms
    pub store_nar_compression_savings: prometheus::Gauge, // hydraqueuerunner_store_nar_compression_savings
    pub store_nar_compression_speed: prometheus::Gauge, // hydraqueuerunner_store_nar_compression_speed

    // S3 metrics (multiple backends)
    pub s3_put: prometheus::IntGaugeVec, // hydraqueuerunner_s3_put
    pub s3_put_bytes: prometheus::IntGaugeVec, // hydraqueuerunner_s3_put_bytes
    pub s3_put_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_s3_put_time_ms
    pub s3_put_speed: prometheus::GaugeVec, // hydraqueuerunner_s3_put_speed
    pub s3_get: prometheus::IntGaugeVec, // hydraqueuerunner_s3_get
    pub s3_get_bytes: prometheus::IntGaugeVec, // hydraqueuerunner_s3_get_bytes
    pub s3_get_time_ms: prometheus::IntGaugeVec, // hydraqueuerunner_s3_get_time_ms
    pub s3_get_speed: prometheus::GaugeVec, // hydraqueuerunner_s3_get_speed
    pub s3_head: prometheus::IntGaugeVec, // hydraqueuerunner_s3_head
    pub s3_cost_dollar_approx: prometheus::GaugeVec, // hydraqueuerunner_s3_cost_dollar_approx

    // Build dependency and complexity metrics
    pub build_input_drvs_histogram: prometheus::HistogramVec, // hydraqueuerunner_build_input_drvs_seconds
    pub build_closure_size_bytes_histogram: prometheus::HistogramVec, // hydraqueuerunner_build_closure_size_bytes

    // Queue performance metrics
    pub queue_sort_duration_ms_total: prometheus::IntCounter, // hydraqueuerunner_sort_duration_ms_total
    pub queue_job_wait_time_histogram: prometheus::HistogramVec, // hydraqueuerunner_job_wait_time_seconds
    pub queue_aborted_jobs_total: prometheus::IntCounter, // hydraqueuerunner_aborted_jobs_total

    // Jobset metrics
    pub jobset_share_used: prometheus::IntGaugeVec, // hydraqueuerunner_jobset_share_used
    pub jobset_seconds: prometheus::IntGaugeVec,    // hydraqueuerunner_jobset_seconds
}

impl PromMetrics {
    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(err)]
    pub fn new() -> anyhow::Result<Self> {
        let queue_checks_started = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_queue_checks_started_total",
            "Number of times State::get_queued_builds() was started",
        ))?;
        let queue_build_loads = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_queue_build_loads_total",
            "Number of builds loaded",
        ))?;
        let queue_steps_created = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_queue_steps_created_total",
            "Number of steps created",
        ))?;
        let queue_checks_early_exits = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_queue_checks_early_exits_total",
            "Number of times State::get_queued_builds() yielded to potential bumps",
        ))?;
        let queue_checks_finished = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_queue_checks_finished_total",
            "Number of times State::get_queued_builds() was completed",
        ))?;
        let dispatcher_time_spent_running =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_dispatcher_time_spent_running_total",
                "Time (in micros) spent running the dispatcher",
            ))?;
        let dispatcher_time_spent_waiting =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_dispatcher_time_spent_waiting_total",
                "Time (in micros) spent waiting for the dispatcher to obtain work",
            ))?;
        let queue_monitor_time_spent_running =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_monitor_time_spent_running_total",
                "Time (in micros) spent running the queue monitor",
            ))?;
        let queue_monitor_time_spent_waiting =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_monitor_time_spent_waiting_total",
                "Time (in micros) spent waiting for the queue monitor to obtain work",
            ))?;

        let nr_builds_read = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_read",
            "Number of builds read from database",
        ))?;
        let build_read_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_read_time_ms",
            "Time in milliseconds spent reading builds from database",
        ))?;
        let nr_builds_unfinished = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_unfinished",
            "Number of unfinished builds in the queue",
        ))?;
        let nr_builds_done = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_finished",
            "Number of finished builds in the queue",
        ))?;
        let nr_builds_succeeded = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_succeeded",
            "Number of successful builds in the queue",
        ))?;
        let nr_builds_failed = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_builds_failed",
            "Number of failed builds in the queue",
        ))?;
        let nr_steps_started = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_started",
            "Number of build steps that have been started",
        ))?;
        let nr_steps_done = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_finished",
            "Number of build steps that have been completed",
        ))?;
        let nr_steps_building = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_building",
            "Number of build steps currently being built",
        ))?;
        let nr_steps_waiting = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_waiting",
            "Number of build steps waiting to be built",
        ))?;
        let nr_steps_runnable = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_runnable",
            "Number of build steps that are ready to run",
        ))?;
        let nr_steps_unfinished = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_unfinished",
            "Number of unfinished build steps",
        ))?;
        let nr_unsupported_steps = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_unsupported",
            "Number of unsupported build steps",
        ))?;
        let nr_unsupported_steps_aborted =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_steps_unsupported_aborted",
                "Number of unsupported build steps that were aborted",
            ))?;
        let nr_substitutes_started = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_substitutes_started",
            "Number of substitute downloads that have been started",
        ))?;
        let nr_substitutes_failed = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_substitutes_failed",
            "Number of substitute downloads that have failed",
        ))?;
        let nr_substitutes_succeeded = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_substitutes_succeeded",
            "Number of substitute downloads that have succeeded",
        ))?;
        let nr_retries = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_retries",
            "Number of retries for build steps",
        ))?;
        let max_nr_retries = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_max_retries",
            "Maximum number of retries allowed for build steps",
        ))?;
        let nr_steps_copying_to = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_copying_to",
            "Number of build steps currently copying inputs to machines",
        ))?;
        let nr_steps_copying_from = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_copying_from",
            "Number of build steps currently copying outputs from machines",
        ))?;
        let avg_step_time_ms = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_avg_total_time_ms",
            "Average time in milliseconds for build steps to complete",
        ))?;
        let avg_step_import_time_ms = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_avg_import_time_ms",
            "Average time in milliseconds for importing build steps",
        ))?;
        let avg_step_build_time_ms = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_avg_build_time_ms",
            "Average time in milliseconds for building build steps",
        ))?;
        let avg_step_upload_time_ms = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_avg_upload_time_ms",
            "Average time in milliseconds for uploading build steps",
        ))?;
        let total_step_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_total_time_ms",
            "Total time in milliseconds spent on all build steps",
        ))?;
        let total_step_import_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_total_import_time_ms",
            "Total time in milliseconds spent importing all build steps",
        ))?;
        let total_step_build_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_total_build_time_ms",
            "Total time in milliseconds spent building all build steps",
        ))?;
        let total_step_upload_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_steps_total_upload_time_ms",
            "Total time in milliseconds spent uploading all build steps",
        ))?;
        let nr_queue_wakeups = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_monitor_checks",
            "Number of times the queue monitor has been woken up",
        ))?;
        let nr_dispatcher_wakeups = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_dispatch_wakeup",
            "Number of times the dispatcher has been woken up",
        ))?;
        let dispatch_time_ms = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_dispatch_time_ms",
            "Time in milliseconds spent dispatching build steps",
        ))?;
        let machines_total = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_machines_total",
            "Total number of machines available for building",
        ))?;
        let machines_in_use = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_machines_in_use",
            "Number of machines currently in use for building",
        ))?;

        // Per-machine-type metrics
        let runnable_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_runnable",
                "Number of runnable build steps per machine type",
            ),
            &["machine_type"],
        )?;
        let running_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_running",
                "Number of running build steps per machine type",
            ),
            &["machine_type"],
        )?;
        let waiting_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_waiting",
                "Number of waiting build steps per machine type",
            ),
            &["machine_type"],
        )?;
        let disabled_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_disabled",
                "Number of disabled build steps per machine type",
            ),
            &["machine_type"],
        )?;
        let avg_runnable_time_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_avg_runnable_time",
                "Average runnable time for build steps per machine type",
            ),
            &["machine_type"],
        )?;
        let wait_time_per_machine_type = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_type_wait_time",
                "Wait time for build steps per machine type",
            ),
            &["machine_type"],
        )?;

        // Per-machine metrics
        let machine_current_jobs = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_current_jobs",
                "Number of currently running jobs on each machine",
            ),
            &["hostname"],
        )?;
        let machine_steps_done = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_steps_done",
                "Total number of steps completed by each machine",
            ),
            &["hostname"],
        )?;
        let machine_total_step_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_total_step_time_ms",
                "Total time in milliseconds spent on all steps by each machine",
            ),
            &["hostname"],
        )?;
        let machine_total_step_import_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_total_step_import_time_ms",
                "Total time in milliseconds spent importing steps by each machine",
            ),
            &["hostname"],
        )?;
        let machine_total_step_build_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_total_step_build_time_ms",
                "Total time in milliseconds spent building steps by each machine",
            ),
            &["hostname"],
        )?;
        let machine_total_step_upload_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_total_step_upload_time_ms",
                "Total time in milliseconds spent uploading steps by each machine",
            ),
            &["hostname"],
        )?;
        let machine_consecutive_failures = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_consecutive_failures",
                "Number of consecutive failures for each machine",
            ),
            &["hostname"],
        )?;
        let machine_last_ping_timestamp = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_last_ping_timestamp",
                "Unix timestamp of the last ping received from each machine",
            ),
            &["hostname"],
        )?;
        let machine_idle_since_timestamp = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_machine_idle_since_timestamp",
                "Unix timestamp since when each machine has been idle (0 if currently busy)",
            ),
            &["hostname"],
        )?;

        // Store metrics (single store)
        let store_nar_info_read = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_info_read",
            "Number of NAR info reads from store",
        ))?;
        let store_nar_info_read_averted = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_info_read_averted",
            "Number of NAR info reads averted from store",
        ))?;
        let store_nar_info_missing = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_info_missing",
            "Number of missing NAR info in store",
        ))?;
        let store_nar_info_write = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_info_write",
            "Number of NAR info writes to store",
        ))?;
        let store_path_info_cache_size = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_path_info_cache_size",
            "Size of path info cache in store",
        ))?;
        let store_nar_read = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_read",
            "Number of NAR reads from store",
        ))?;
        let store_nar_read_bytes = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_read_bytes",
            "Number of bytes read from NARs in store",
        ))?;
        let store_nar_read_compressed_bytes =
            prometheus::IntGauge::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_store_nar_read_compressed_bytes",
                "Number of compressed bytes read from NARs in store",
            ))?;
        let store_nar_write = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_write",
            "Number of NAR writes to store",
        ))?;
        let store_nar_write_averted = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_write_averted",
            "Number of NAR writes averted to store",
        ))?;
        let store_nar_write_bytes = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_write_bytes",
            "Number of bytes written to NARs in store",
        ))?;
        let store_nar_write_compressed_bytes =
            prometheus::IntGauge::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_store_nar_write_compressed_bytes",
                "Number of compressed bytes written to NARs in store",
            ))?;
        let store_nar_write_compression_time_ms =
            prometheus::IntGauge::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_store_nar_write_compression_time_ms",
                "Time in milliseconds spent compressing NARs in store",
            ))?;
        let store_nar_compression_savings = prometheus::Gauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_compression_savings",
            "Compression savings ratio for NARs in store",
        ))?;
        let store_nar_compression_speed = prometheus::Gauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_store_nar_compression_speed",
            "Compression speed for NARs in store",
        ))?;

        // S3 metrics (multiple backends)
        let s3_put = prometheus::IntGaugeVec::new(
            prometheus::Opts::new("hydraqueuerunner_s3_put", "Number of S3 put operations"),
            &["remote_store"],
        )?;
        let s3_put_bytes = prometheus::IntGaugeVec::new(
            prometheus::Opts::new("hydraqueuerunner_s3_put_bytes", "Number of bytes put to S3"),
            &["remote_store"],
        )?;
        let s3_put_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_put_time_ms",
                "Time in milliseconds spent on S3 put operations",
            ),
            &["remote_store"],
        )?;
        let s3_put_speed = prometheus::GaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_put_speed",
                "Speed of S3 put operations",
            ),
            &["remote_store"],
        )?;
        let s3_get = prometheus::IntGaugeVec::new(
            prometheus::Opts::new("hydraqueuerunner_s3_get", "Number of S3 get operations"),
            &["remote_store"],
        )?;
        let s3_get_bytes = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_get_bytes",
                "Number of bytes gotten from S3",
            ),
            &["remote_store"],
        )?;
        let s3_get_time_ms = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_get_time_ms",
                "Time in milliseconds spent on S3 get operations",
            ),
            &["remote_store"],
        )?;
        let s3_get_speed = prometheus::GaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_get_speed",
                "Speed of S3 get operations",
            ),
            &["remote_store"],
        )?;
        let s3_head = prometheus::IntGaugeVec::new(
            prometheus::Opts::new("hydraqueuerunner_s3_head", "Number of S3 head operations"),
            &["remote_store"],
        )?;
        let s3_cost_dollar_approx = prometheus::GaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_s3_cost_dollar_approx",
                "Approximate cost in dollars for S3 operations",
            ),
            &["remote_store"],
        )?;

        // Build dependency and complexity metrics
        let build_input_drvs_histogram = prometheus::HistogramVec::new(
            prometheus::HistogramOpts::new(
                "hydraqueuerunner_build_input_drvs_seconds",
                "Distribution of number of input derivations per build",
            )
            .buckets(vec![
                0.0,
                1.0,
                5.0,
                10.0,
                25.0,
                50.0,
                100.0,
                250.0,
                500.0,
                f64::INFINITY,
            ]),
            &["machine_type"],
        )?;
        let build_closure_size_bytes_histogram = prometheus::HistogramVec::new(
            prometheus::HistogramOpts::new(
                "hydraqueuerunner_build_closure_size_bytes",
                "Distribution of build closure sizes in bytes",
            )
            .buckets(vec![
                1000.0,
                10_000.0,
                100_000.0,
                1_000_000.0,
                10_000_000.0,
                100_000_000.0,
                1_000_000_000.0,
                f64::INFINITY,
            ]),
            &["machine_type"],
        )?;

        // Queue performance metrics
        let queue_sort_duration_ms_total =
            prometheus::IntCounter::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_sort_duration_ms_total",
                "Total time in milliseconds spent sorting jobs in queues",
            ))?;
        let queue_job_wait_time_histogram = prometheus::HistogramVec::new(
            prometheus::HistogramOpts::new(
                "hydraqueuerunner_job_wait_time_seconds",
                "Distribution of time jobs wait in queue before being scheduled",
            )
            .buckets(vec![
                1.0,
                10.0,
                60.0,
                300.0,
                900.0,
                3600.0,
                7200.0,
                86400.0,
                f64::INFINITY,
            ]),
            &["machine_type"],
        )?;

        let queue_aborted_jobs_total = prometheus::IntCounter::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_aborted_jobs_total",
            "Total number of jobs that were aborted",
        ))?;

        // Jobset metrics
        let jobset_share_used = prometheus::IntGaugeVec::new(
            prometheus::Opts::new("hydraqueuerunner_jobset_share_used", "Share used by jobset"),
            &["jobset_name"],
        )?;
        let jobset_seconds = prometheus::IntGaugeVec::new(
            prometheus::Opts::new(
                "hydraqueuerunner_jobset_seconds",
                "Seconds allocated to jobset",
            ),
            &["jobset_name"],
        )?;

        // Queue runner time metrics
        let queue_runner_current_time_seconds =
            prometheus::IntGauge::with_opts(prometheus::Opts::new(
                "hydraqueuerunner_current_time_seconds",
                "Current Unix timestamp in seconds",
            ))?;
        let queue_runner_uptime_seconds = prometheus::IntGauge::with_opts(prometheus::Opts::new(
            "hydraqueuerunner_uptime_seconds",
            "Queue runner uptime in seconds",
        ))?;

        let r = prometheus::default_registry();
        r.register(Box::new(queue_checks_started.clone()))?;
        r.register(Box::new(queue_build_loads.clone()))?;
        r.register(Box::new(queue_steps_created.clone()))?;
        r.register(Box::new(queue_checks_early_exits.clone()))?;
        r.register(Box::new(queue_checks_finished.clone()))?;
        r.register(Box::new(dispatcher_time_spent_running.clone()))?;
        r.register(Box::new(dispatcher_time_spent_waiting.clone()))?;
        r.register(Box::new(queue_monitor_time_spent_running.clone()))?;
        r.register(Box::new(queue_monitor_time_spent_waiting.clone()))?;
        r.register(Box::new(nr_builds_read.clone()))?;
        r.register(Box::new(build_read_time_ms.clone()))?;
        r.register(Box::new(nr_builds_unfinished.clone()))?;
        r.register(Box::new(nr_builds_done.clone()))?;
        r.register(Box::new(nr_builds_succeeded.clone()))?;
        r.register(Box::new(nr_builds_failed.clone()))?;
        r.register(Box::new(nr_steps_started.clone()))?;
        r.register(Box::new(nr_steps_done.clone()))?;
        r.register(Box::new(nr_steps_building.clone()))?;
        r.register(Box::new(nr_steps_waiting.clone()))?;
        r.register(Box::new(nr_steps_runnable.clone()))?;
        r.register(Box::new(nr_steps_unfinished.clone()))?;
        r.register(Box::new(nr_unsupported_steps.clone()))?;
        r.register(Box::new(nr_unsupported_steps_aborted.clone()))?;
        r.register(Box::new(nr_substitutes_started.clone()))?;
        r.register(Box::new(nr_substitutes_failed.clone()))?;
        r.register(Box::new(nr_substitutes_succeeded.clone()))?;
        r.register(Box::new(nr_retries.clone()))?;
        r.register(Box::new(max_nr_retries.clone()))?;
        r.register(Box::new(nr_steps_copying_to.clone()))?;
        r.register(Box::new(nr_steps_copying_from.clone()))?;
        r.register(Box::new(avg_step_time_ms.clone()))?;
        r.register(Box::new(avg_step_import_time_ms.clone()))?;
        r.register(Box::new(avg_step_build_time_ms.clone()))?;
        r.register(Box::new(avg_step_upload_time_ms.clone()))?;
        r.register(Box::new(total_step_time_ms.clone()))?;
        r.register(Box::new(total_step_import_time_ms.clone()))?;
        r.register(Box::new(total_step_build_time_ms.clone()))?;
        r.register(Box::new(total_step_upload_time_ms.clone()))?;
        r.register(Box::new(nr_queue_wakeups.clone()))?;
        r.register(Box::new(nr_dispatcher_wakeups.clone()))?;
        r.register(Box::new(dispatch_time_ms.clone()))?;
        r.register(Box::new(machines_total.clone()))?;
        r.register(Box::new(machines_in_use.clone()))?;
        r.register(Box::new(runnable_per_machine_type.clone()))?;
        r.register(Box::new(running_per_machine_type.clone()))?;
        r.register(Box::new(waiting_per_machine_type.clone()))?;
        r.register(Box::new(disabled_per_machine_type.clone()))?;
        r.register(Box::new(avg_runnable_time_per_machine_type.clone()))?;
        r.register(Box::new(wait_time_per_machine_type.clone()))?;
        r.register(Box::new(machine_current_jobs.clone()))?;
        r.register(Box::new(machine_steps_done.clone()))?;
        r.register(Box::new(machine_total_step_time_ms.clone()))?;
        r.register(Box::new(machine_total_step_import_time_ms.clone()))?;
        r.register(Box::new(machine_total_step_build_time_ms.clone()))?;
        r.register(Box::new(machine_total_step_upload_time_ms.clone()))?;
        r.register(Box::new(machine_consecutive_failures.clone()))?;
        r.register(Box::new(machine_last_ping_timestamp.clone()))?;
        r.register(Box::new(machine_idle_since_timestamp.clone()))?;

        // Store metrics
        r.register(Box::new(store_nar_info_read.clone()))?;
        r.register(Box::new(store_nar_info_read_averted.clone()))?;
        r.register(Box::new(store_nar_info_missing.clone()))?;
        r.register(Box::new(store_nar_info_write.clone()))?;
        r.register(Box::new(store_path_info_cache_size.clone()))?;
        r.register(Box::new(store_nar_read.clone()))?;
        r.register(Box::new(store_nar_read_bytes.clone()))?;
        r.register(Box::new(store_nar_read_compressed_bytes.clone()))?;
        r.register(Box::new(store_nar_write.clone()))?;
        r.register(Box::new(store_nar_write_averted.clone()))?;
        r.register(Box::new(store_nar_write_bytes.clone()))?;
        r.register(Box::new(store_nar_write_compressed_bytes.clone()))?;
        r.register(Box::new(store_nar_write_compression_time_ms.clone()))?;
        r.register(Box::new(store_nar_compression_savings.clone()))?;
        r.register(Box::new(store_nar_compression_speed.clone()))?;

        // S3 metrics
        r.register(Box::new(s3_put.clone()))?;
        r.register(Box::new(s3_put_bytes.clone()))?;
        r.register(Box::new(s3_put_time_ms.clone()))?;
        r.register(Box::new(s3_put_speed.clone()))?;
        r.register(Box::new(s3_get.clone()))?;
        r.register(Box::new(s3_get_bytes.clone()))?;
        r.register(Box::new(s3_get_time_ms.clone()))?;
        r.register(Box::new(s3_get_speed.clone()))?;
        r.register(Box::new(s3_head.clone()))?;
        r.register(Box::new(s3_cost_dollar_approx.clone()))?;

        // Build dependency and complexity metrics
        r.register(Box::new(build_input_drvs_histogram.clone()))?;
        r.register(Box::new(build_closure_size_bytes_histogram.clone()))?;

        // Queue performance metrics
        r.register(Box::new(queue_sort_duration_ms_total.clone()))?;
        r.register(Box::new(queue_job_wait_time_histogram.clone()))?;
        r.register(Box::new(queue_aborted_jobs_total.clone()))?;

        // Jobset metrics
        r.register(Box::new(jobset_share_used.clone()))?;
        r.register(Box::new(jobset_seconds.clone()))?;

        // Queue runner time metrics
        r.register(Box::new(queue_runner_current_time_seconds.clone()))?;
        r.register(Box::new(queue_runner_uptime_seconds.clone()))?;

        Ok(Self {
            queue_runner_current_time_seconds,
            queue_runner_uptime_seconds,
            queue_checks_started,
            queue_build_loads,
            queue_steps_created,
            queue_checks_early_exits,
            queue_checks_finished,
            dispatcher_time_spent_running,
            dispatcher_time_spent_waiting,
            queue_monitor_time_spent_running,
            queue_monitor_time_spent_waiting,
            nr_builds_read,
            build_read_time_ms,
            nr_builds_unfinished,
            nr_builds_done,
            nr_builds_succeeded,
            nr_builds_failed,
            nr_steps_started,
            nr_steps_done,
            nr_steps_building,
            nr_steps_waiting,
            nr_steps_runnable,
            nr_steps_unfinished,
            nr_unsupported_steps,
            nr_unsupported_steps_aborted,
            nr_substitutes_started,
            nr_substitutes_failed,
            nr_substitutes_succeeded,
            nr_retries,
            max_nr_retries,
            nr_steps_copying_to,
            nr_steps_copying_from,
            avg_step_time_ms,
            avg_step_import_time_ms,
            avg_step_build_time_ms,
            avg_step_upload_time_ms,
            total_step_time_ms,
            total_step_import_time_ms,
            total_step_build_time_ms,
            total_step_upload_time_ms,
            nr_queue_wakeups,
            nr_dispatcher_wakeups,
            dispatch_time_ms,
            machines_total,
            machines_in_use,
            runnable_per_machine_type,
            running_per_machine_type,
            waiting_per_machine_type,
            disabled_per_machine_type,
            avg_runnable_time_per_machine_type,
            wait_time_per_machine_type,
            machine_current_jobs,
            machine_steps_done,
            machine_total_step_time_ms,
            machine_total_step_import_time_ms,
            machine_total_step_build_time_ms,
            machine_total_step_upload_time_ms,
            machine_consecutive_failures,
            machine_last_ping_timestamp,
            machine_idle_since_timestamp,

            // Store metrics
            store_nar_info_read,
            store_nar_info_read_averted,
            store_nar_info_missing,
            store_nar_info_write,
            store_path_info_cache_size,
            store_nar_read,
            store_nar_read_bytes,
            store_nar_read_compressed_bytes,
            store_nar_write,
            store_nar_write_averted,
            store_nar_write_bytes,
            store_nar_write_compressed_bytes,
            store_nar_write_compression_time_ms,
            store_nar_compression_savings,
            store_nar_compression_speed,

            // S3 metrics
            s3_put,
            s3_put_bytes,
            s3_put_time_ms,
            s3_put_speed,
            s3_get,
            s3_get_bytes,
            s3_get_time_ms,
            s3_get_speed,
            s3_head,
            s3_cost_dollar_approx,

            // Build dependency and complexity metrics
            build_input_drvs_histogram,
            build_closure_size_bytes_histogram,

            // Queue performance metrics
            queue_sort_duration_ms_total,
            queue_job_wait_time_histogram,
            queue_aborted_jobs_total,

            // Jobset metrics
            jobset_share_used,
            jobset_seconds,
        })
    }

    pub async fn refresh_dynamic_metrics(&self, state: &Arc<super::State>) {
        let nr_steps_done = self.nr_steps_done.get();
        if nr_steps_done > 0 {
            let avg_time = self.total_step_time_ms.get() / nr_steps_done;
            let avg_import_time = self.total_step_import_time_ms.get() / nr_steps_done;
            let avg_build_time = self.total_step_build_time_ms.get() / nr_steps_done;
            let avg_upload_time = self.total_step_upload_time_ms.get() / nr_steps_done;

            if let Ok(v) = i64::try_from(avg_time) {
                self.avg_step_time_ms.set(v);
            }
            if let Ok(v) = i64::try_from(avg_import_time) {
                self.avg_step_import_time_ms.set(v);
            }
            if let Ok(v) = i64::try_from(avg_upload_time) {
                self.avg_step_upload_time_ms.set(v);
            }
            if let Ok(v) = i64::try_from(avg_build_time) {
                self.avg_step_build_time_ms.set(v);
            }
        }

        if let Ok(v) = i64::try_from(state.builds.len()) {
            self.nr_builds_unfinished.set(v);
        }
        if let Ok(v) = i64::try_from(state.steps.len()) {
            self.nr_steps_unfinished.set(v);
        }
        if let Ok(v) = i64::try_from(state.steps.len_runnable()) {
            self.nr_steps_runnable.set(v);
        }
        if let Ok(v) = i64::try_from(state.machines.get_machine_count()) {
            self.machines_total.set(v);
        }
        if let Ok(v) = i64::try_from(state.machines.get_machine_count_in_use()) {
            self.machines_in_use.set(v);
        }

        self.refresh_per_machine_type_metrics(state).await;
        self.refresh_per_machine_metrics(state);
        self.refresh_store_metrics(state);
        self.refresh_s3_metrics(state);
        self.refresh_transfer_metrics(state);
        self.refresh_jobset_metrics(state);
        self.refresh_time_metrics(state);
    }

    async fn refresh_per_machine_type_metrics(&self, state: &Arc<super::State>) {
        self.runnable_per_machine_type.reset();
        self.running_per_machine_type.reset();
        self.waiting_per_machine_type.reset();
        self.disabled_per_machine_type.reset();
        self.avg_runnable_time_per_machine_type.reset();
        self.wait_time_per_machine_type.reset();
        for (t, s) in state.queues.get_stats_per_queue().await {
            if let Ok(v) = i64::try_from(s.total_runnable) {
                self.runnable_per_machine_type
                    .with_label_values(std::slice::from_ref(&t))
                    .set(v);
            }
            if let Ok(v) = i64::try_from(s.active_runnable) {
                self.running_per_machine_type
                    .with_label_values(&[&t])
                    .set(v);
            }
            if let Ok(v) = i64::try_from(s.nr_runnable_waiting) {
                self.waiting_per_machine_type
                    .with_label_values(&[&t])
                    .set(v);
            }
            if let Ok(v) = i64::try_from(s.nr_runnable_disabled) {
                self.disabled_per_machine_type
                    .with_label_values(&[&t])
                    .set(v);
            }
            if let Ok(v) = i64::try_from(s.avg_runnable_time) {
                self.avg_runnable_time_per_machine_type
                    .with_label_values(&[&t])
                    .set(v);
            }
            if let Ok(v) = i64::try_from(s.wait_time) {
                self.wait_time_per_machine_type
                    .with_label_values(&[&t])
                    .set(v);
            }
        }
    }

    fn refresh_per_machine_metrics(&self, state: &Arc<super::State>) {
        self.machine_current_jobs.reset();
        self.machine_steps_done.reset();
        self.machine_total_step_time_ms.reset();
        self.machine_total_step_import_time_ms.reset();
        self.machine_total_step_build_time_ms.reset();
        self.machine_total_step_upload_time_ms.reset();
        self.machine_consecutive_failures.reset();
        self.machine_last_ping_timestamp.reset();
        self.machine_idle_since_timestamp.reset();

        for machine in state.machines.get_all_machines() {
            let hostname = &machine.hostname;

            let labels = &[hostname];

            if let Ok(v) = i64::try_from(machine.stats.get_current_jobs()) {
                self.machine_current_jobs.with_label_values(labels).set(v);
            }

            if let Ok(v) = i64::try_from(machine.stats.get_nr_steps_done()) {
                self.machine_steps_done.with_label_values(labels).set(v);
            }
            if let Ok(v) = i64::try_from(machine.stats.get_total_step_time_ms()) {
                self.machine_total_step_time_ms
                    .with_label_values(labels)
                    .set(v);
            }
            if let Ok(v) = i64::try_from(machine.stats.get_total_step_import_time_ms()) {
                self.machine_total_step_import_time_ms
                    .with_label_values(labels)
                    .set(v);
            }
            if let Ok(v) = i64::try_from(machine.stats.get_total_step_build_time_ms()) {
                self.machine_total_step_build_time_ms
                    .with_label_values(labels)
                    .set(v);
            }
            if let Ok(v) = i64::try_from(machine.stats.get_total_step_upload_time_ms()) {
                self.machine_total_step_upload_time_ms
                    .with_label_values(labels)
                    .set(v);
            }

            if let Ok(v) = i64::try_from(machine.stats.get_consecutive_failures()) {
                self.machine_consecutive_failures
                    .with_label_values(labels)
                    .set(v);
            }
            self.machine_last_ping_timestamp
                .with_label_values(labels)
                .set(machine.stats.get_last_ping());
            self.machine_idle_since_timestamp
                .with_label_values(labels)
                .set(machine.stats.get_idle_since());
        }
    }

    fn refresh_store_metrics(&self, state: &Arc<super::State>) {
        if let Ok(store_stats) = state.store.get_store_stats() {
            if let Ok(v) = i64::try_from(store_stats.nar_info_read) {
                self.store_nar_info_read.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_info_read_averted) {
                self.store_nar_info_read_averted.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_info_missing) {
                self.store_nar_info_missing.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_info_write) {
                self.store_nar_info_write.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.path_info_cache_size) {
                self.store_path_info_cache_size.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_read) {
                self.store_nar_read.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_read_bytes) {
                self.store_nar_read_bytes.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_read_compressed_bytes) {
                self.store_nar_read_compressed_bytes.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_write) {
                self.store_nar_write.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_write_averted) {
                self.store_nar_write_averted.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_write_bytes) {
                self.store_nar_write_bytes.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_write_compressed_bytes) {
                self.store_nar_write_compressed_bytes.set(v);
            }
            if let Ok(v) = i64::try_from(store_stats.nar_write_compression_time_ms) {
                self.store_nar_write_compression_time_ms.set(v);
            }
            self.store_nar_compression_savings
                .set(store_stats.nar_compression_savings());
            self.store_nar_compression_speed
                .set(store_stats.nar_compression_speed());
        }
    }

    fn refresh_s3_metrics(&self, state: &Arc<super::State>) {
        self.s3_put.reset();
        self.s3_put_bytes.reset();
        self.s3_put_time_ms.reset();
        self.s3_put_speed.reset();
        self.s3_get.reset();
        self.s3_get_bytes.reset();
        self.s3_get_time_ms.reset();
        self.s3_get_speed.reset();
        self.s3_head.reset();
        self.s3_cost_dollar_approx.reset();

        let s3_backends = state.remote_stores.read();
        for remote_store in s3_backends.iter() {
            let backend_name = &remote_store.cfg.client_config.bucket;
            let s3_stats = remote_store.s3_stats();
            let labels = &[backend_name.as_str()];

            if let Ok(v) = i64::try_from(s3_stats.put) {
                self.s3_put.with_label_values(labels).set(v);
            }
            if let Ok(v) = i64::try_from(s3_stats.put_bytes) {
                self.s3_put_bytes.with_label_values(labels).set(v);
            }
            if let Ok(v) = i64::try_from(s3_stats.put_time_ms) {
                self.s3_put_time_ms.with_label_values(labels).set(v);
            }
            self.s3_put_speed
                .with_label_values(labels)
                .set(s3_stats.put_speed());
            if let Ok(v) = i64::try_from(s3_stats.get) {
                self.s3_get.with_label_values(labels).set(v);
            }
            if let Ok(v) = i64::try_from(s3_stats.get_bytes) {
                self.s3_get_bytes.with_label_values(labels).set(v);
            }
            if let Ok(v) = i64::try_from(s3_stats.get_time_ms) {
                self.s3_get_time_ms.with_label_values(labels).set(v);
            }
            self.s3_get_speed
                .with_label_values(labels)
                .set(s3_stats.get_speed());
            if let Ok(v) = i64::try_from(s3_stats.head) {
                self.s3_head.with_label_values(labels).set(v);
            }
            self.s3_cost_dollar_approx
                .with_label_values(labels)
                .set(s3_stats.cost_dollar_approx());
        }
    }

    fn refresh_transfer_metrics(&self, state: &Arc<super::State>) {
        let mut total_uploading_path_count = 0u64;
        let mut total_downloading_path_count = 0u64;

        for machine in state.machines.get_all_machines() {
            total_uploading_path_count += machine.stats.get_current_uploading_path_count();
            total_downloading_path_count += machine.stats.get_current_downloading_count();
        }

        if let Ok(v) = i64::try_from(total_uploading_path_count) {
            self.nr_steps_copying_to.set(v);
        }
        if let Ok(v) = i64::try_from(total_downloading_path_count) {
            self.nr_steps_copying_from.set(v);
        }
    }

    fn refresh_jobset_metrics(&self, state: &Arc<super::State>) {
        self.jobset_share_used.reset();
        self.jobset_seconds.reset();

        let jobsets = state.jobsets.clone_as_io();
        for (full_jobset_name, jobset) in &jobsets {
            let labels = &[full_jobset_name.as_str()];

            let v = i64::try_from(u64::from(jobset.shares)).unwrap_or(0);
            self.jobset_share_used.with_label_values(labels).set(v);

            self.jobset_seconds
                .with_label_values(labels)
                .set(jobset.seconds);
        }
    }

    fn refresh_time_metrics(&self, state: &Arc<super::State>) {
        let now = jiff::Timestamp::now();

        self.queue_runner_current_time_seconds.set(now.as_second());
        #[allow(clippy::cast_possible_truncation)]
        self.queue_runner_uptime_seconds.set(
            (now - state.started_at)
                .total(jiff::Unit::Second)
                .unwrap_or_default() as i64,
        );
    }

    #[tracing::instrument(skip(self, state), err)]
    pub async fn gather_metrics(&self, state: &Arc<super::State>) -> anyhow::Result<Vec<u8>> {
        self.refresh_dynamic_metrics(state).await;

        let mut buffer = Vec::new();
        let encoder = prometheus::TextEncoder::new();
        let metric_families = prometheus::gather();
        encoder.encode(&metric_families, &mut buffer)?;

        Ok(buffer)
    }

    fn add_to_total_step_time_ms(&self, v: u64) {
        self.total_step_time_ms.inc_by(v);
    }

    fn add_to_total_step_import_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_import_time_ms.inc_by(v);
        }
    }

    fn add_to_total_step_build_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_build_time_ms.inc_by(v);
        }
    }

    fn add_to_total_step_upload_time_ms(&self, v: u128) {
        if let Ok(v) = u64::try_from(v) {
            self.total_step_upload_time_ms.inc_by(v);
        }
    }

    pub fn observe_build_input_drvs(&self, count: f64, machine_type: &str) {
        self.build_input_drvs_histogram
            .with_label_values(&[machine_type])
            .observe(count);
    }

    pub fn observe_build_closure_size(&self, size_bytes: f64, machine_type: &str) {
        self.build_closure_size_bytes_histogram
            .with_label_values(&[machine_type])
            .observe(size_bytes);
    }

    pub fn observe_job_wait_time(&self, wait_seconds: f64, machine_type: &str) {
        self.queue_job_wait_time_histogram
            .with_label_values(&[machine_type])
            .observe(wait_seconds);
    }

    pub fn track_build_success(&self, timings: super::build::BuildTimings, total_step_time: u64) {
        self.nr_builds_succeeded.inc();
        self.nr_steps_done.inc();
        self.nr_steps_building.sub(1);
        self.add_to_total_step_import_time_ms(timings.import_elapsed.as_millis());
        self.add_to_total_step_build_time_ms(timings.build_elapsed.as_millis());
        self.add_to_total_step_upload_time_ms(timings.upload_elapsed.as_millis());
        self.add_to_total_step_time_ms(total_step_time);
    }

    pub fn track_build_failure(&self, timings: super::build::BuildTimings, total_step_time: u64) {
        self.nr_steps_done.inc();
        self.nr_steps_building.sub(1);
        self.nr_builds_failed.inc();
        self.add_to_total_step_import_time_ms(timings.import_elapsed.as_millis());
        self.add_to_total_step_build_time_ms(timings.build_elapsed.as_millis());
        self.add_to_total_step_upload_time_ms(timings.upload_elapsed.as_millis());
        self.add_to_total_step_time_ms(total_step_time);
    }
}
