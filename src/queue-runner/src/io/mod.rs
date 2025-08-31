pub mod build;
pub mod jobset;
pub mod machine;
pub mod queue_runner;
pub mod response_types;
pub mod stats;
pub mod step;
pub mod step_info;

pub use build::{Build, BuildPayload};
pub use jobset::Jobset;
pub use machine::{Machine, MachineStats};
pub use queue_runner::QueueRunnerStats;
pub use response_types::{
    BuildsResponse, DumpResponse, JobsetsResponse, MachinesResponse, QueueResponse,
    StepInfoResponse, StepsResponse,
};
pub use stats::{BuildQueueStats, CgroupStats, CpuStats, IoStats, MemoryStats, Process};
pub use step::Step;
pub use step_info::StepInfo;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Empty {}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Error {
    pub error: String,
}
