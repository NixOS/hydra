use hashbrown::HashMap;

use nix_utils::BaseStore as _;

use super::{
    Build, Jobset, Machine, QueueRunnerStats, Step, StepInfo, stats::S3Stats, stats::StoreStats,
};

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachinesResponse {
    machines: HashMap<String, Machine>,
    machines_count: usize,
}

impl MachinesResponse {
    #[must_use]
    pub fn new(machines: HashMap<String, Machine>) -> Self {
        Self {
            machines_count: machines.len(),
            machines,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DumpResponse {
    queue_runner: QueueRunnerStats,
    machines: HashMap<String, Machine>,
    jobsets: HashMap<String, Jobset>,
    store: Option<StoreStats>,
    s3: HashMap<String, S3Stats>,
}

impl DumpResponse {
    #[must_use]
    pub fn new(
        queue_runner: QueueRunnerStats,
        machines: HashMap<String, Machine>,
        jobsets: HashMap<String, Jobset>,
        local_store: &nix_utils::LocalStore,
        remote_stores: &[binary_cache::S3BinaryCacheClient],
    ) -> Self {
        let store = local_store
            .get_store_stats()
            .map_or(None, |s| Some(StoreStats::new(&s)));

        Self {
            queue_runner,
            machines,
            jobsets,
            store,
            s3: remote_stores
                .iter()
                .map(|s| {
                    (
                        s.cfg.client_config.bucket.clone(),
                        S3Stats::new(&s.s3_stats()),
                    )
                })
                .collect(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobsetsResponse {
    jobsets: HashMap<String, Jobset>,
    jobset_count: usize,
}

impl JobsetsResponse {
    #[must_use]
    pub fn new(jobsets: HashMap<String, Jobset>) -> Self {
        Self {
            jobset_count: jobsets.len(),
            jobsets,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildsResponse {
    builds: Vec<Build>,
    build_count: usize,
}

impl BuildsResponse {
    #[must_use]
    pub const fn new(builds: Vec<Build>) -> Self {
        Self {
            build_count: builds.len(),
            builds,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepsResponse {
    steps: Vec<Step>,
    step_count: usize,
}

impl StepsResponse {
    #[must_use]
    pub const fn new(steps: Vec<Step>) -> Self {
        Self {
            step_count: steps.len(),
            steps,
        }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueResponse {
    queues: HashMap<String, Vec<StepInfo>>,
}

impl QueueResponse {
    #[must_use]
    pub const fn new(queues: HashMap<String, Vec<StepInfo>>) -> Self {
        Self { queues }
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepInfoResponse {
    steps: Vec<StepInfo>,
    step_count: usize,
}

impl StepInfoResponse {
    #[must_use]
    pub const fn new(steps: Vec<StepInfo>) -> Self {
        Self {
            step_count: steps.len(),
            steps,
        }
    }
}
