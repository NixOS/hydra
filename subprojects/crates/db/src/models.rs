use harmonia_store_core::derived_path::OutputName;
use harmonia_store_core::store_path::{ParseStorePathError, StoreDir, StorePath};
use hashbrown::HashMap;

pub type BuildID = i32;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildStatus {
    Success = 0,
    Failed = 1,
    /// builds only
    DepFailed = 2,
    Aborted = 3,
    Cancelled = 4,
    /// builds only
    FailedWithOutput = 6,
    TimedOut = 7,
    /// steps only
    CachedFailure = 8,
    Unsupported = 9,
    LogLimitExceeded = 10,
    NarSizeLimitExceeded = 11,
    NotDeterministic = 12,
    /// step was resolved to a CA derivation, see resolvedTo FK
    Resolved = 13,
    /// not stored
    Busy = 100,
}

impl BuildStatus {
    #[must_use]
    pub const fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(Self::Success),
            1 => Some(Self::Failed),
            2 => Some(Self::DepFailed),
            3 => Some(Self::Aborted),
            4 => Some(Self::Cancelled),
            6 => Some(Self::FailedWithOutput),
            7 => Some(Self::TimedOut),
            8 => Some(Self::CachedFailure),
            9 => Some(Self::Unsupported),
            10 => Some(Self::LogLimitExceeded),
            11 => Some(Self::NarSizeLimitExceeded),
            12 => Some(Self::NotDeterministic),
            13 => Some(Self::Resolved),
            100 => Some(Self::Busy),
            _ => None,
        }
    }
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepStatus {
    Preparing = 1,
    Connecting = 10,
    SendingInputs = 20,
    Building = 30,
    WaitingForLocalSlot = 35,
    ReceivingOutputs = 40,
    PostProcessing = 50,
}

#[derive(Debug)]
pub struct Jobset {
    pub project: String,
    pub name: String,
    pub schedulingshares: i32,
}

#[derive(Debug, Clone, Copy)]
pub struct BuildSmall {
    pub id: BuildID,
    pub globalpriority: i32,
}

#[derive(Debug)]
pub struct Build<StorePath = harmonia_store_core::store_path::StorePath> {
    pub id: BuildID,
    pub jobset_id: i32,
    pub project: String,
    pub jobset: String,
    pub job: String,
    pub drvpath: StorePath,
    /// maxsilent integer default 3600
    pub maxsilent: Option<i32>,
    /// timeout integer default 36000
    pub timeout: Option<i32>,
    pub timestamp: i64,
    pub globalpriority: i32,
    pub priority: i32,
}

impl Build<String> {
    pub fn parse_paths(self, store_dir: &StoreDir) -> Result<Build, ParseStorePathError> {
        Ok(Build {
            id: self.id,
            jobset_id: self.jobset_id,
            project: self.project,
            jobset: self.jobset,
            job: self.job,
            drvpath: store_dir.parse(&self.drvpath)?,
            maxsilent: self.maxsilent,
            timeout: self.timeout,
            timestamp: self.timestamp,
            globalpriority: self.globalpriority,
            priority: self.priority,
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub struct BuildSteps {
    pub starttime: Option<i32>,
    pub stoptime: Option<i32>,
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildType {
    Build = 0,
    Substitution = 1,
}

#[derive(Debug)]
pub struct UpdateBuild<'a> {
    pub status: BuildStatus,
    pub start_time: i32,
    pub stop_time: i32,
    pub size: i64,
    pub closure_size: i64,
    pub release_name: Option<&'a str>,
    pub is_cached_build: bool,
}

#[derive(Debug)]
pub struct InsertBuildStep<'a> {
    pub build_id: BuildID,
    pub r#type: BuildType,
    pub drv_path: &'a StorePath,
    pub status: BuildStatus,
    pub busy: bool,
    pub start_time: Option<i32>,
    pub stop_time: Option<i32>,
    pub platform: Option<&'a str>,
    pub propagated_from: Option<i32>,
    pub error_msg: Option<&'a str>,
    pub machine: &'a str,
}

#[derive(Debug)]
pub struct InsertBuildStepOutput<StorePath = harmonia_store_core::store_path::StorePath> {
    pub build_id: BuildID,
    pub step_nr: i32,
    pub name: OutputName,
    pub path: Option<StorePath>,
}

impl InsertBuildStepOutput<String> {
    pub fn parse_paths(
        self,
        store_dir: &StoreDir,
    ) -> Result<InsertBuildStepOutput, ParseStorePathError> {
        Ok(InsertBuildStepOutput {
            build_id: self.build_id,
            step_nr: self.step_nr,
            name: self.name,
            path: self.path.map(|p| store_dir.parse(&p)).transpose()?,
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub struct UpdateBuildStep {
    pub build_id: BuildID,
    pub step_nr: i32,
    pub status: StepStatus,
}

#[derive(Debug)]
pub struct UpdateBuildStepInFinish<'a> {
    pub build_id: BuildID,
    pub step_nr: i32,
    pub status: BuildStatus,
    pub error_msg: Option<&'a str>,
    pub start_time: i32,
    pub stop_time: i32,
    pub machine: Option<&'a str>,
    pub overhead: Option<i32>,
    pub times_built: Option<i32>,
    pub is_non_deterministic: Option<bool>,
}

#[derive(Debug)]
pub struct InsertBuildProduct<'a> {
    pub build_id: BuildID,
    pub product_nr: i32,
    pub r#type: &'a str,
    pub subtype: &'a str,
    pub file_size: Option<i64>,
    pub sha256hash: Option<&'a str>,
    pub path: &'a str,
    pub name: &'a str,
    pub default_path: &'a str,
}

#[derive(Debug)]
pub struct InsertBuildMetric<'a> {
    pub build_id: BuildID,
    pub name: &'a str,
    pub unit: Option<&'a str>,
    pub value: f64,
    pub project: &'a str,
    pub jobset: &'a str,
    pub job: &'a str,
    pub timestamp: i32,
}

#[derive(Debug)]
pub struct BuildOutput {
    pub id: i32,
    pub buildstatus: Option<i32>,
    pub releasename: Option<String>,
    pub closuresize: Option<i64>,
    pub size: Option<i64>,
}

#[derive(Debug)]
pub struct OwnedBuildProduct<StorePath = harmonia_store_core::store_path::StorePath> {
    pub r#type: String,
    pub subtype: String,
    pub filesize: Option<i64>,
    pub sha256hash: Option<String>,
    pub path: Option<StorePath>,
    pub name: String,
    pub defaultpath: Option<String>,
}

impl OwnedBuildProduct<String> {
    pub fn parse_paths(
        self,
        store_dir: &StoreDir,
    ) -> Result<OwnedBuildProduct, ParseStorePathError> {
        Ok(OwnedBuildProduct {
            r#type: self.r#type,
            subtype: self.subtype,
            filesize: self.filesize,
            sha256hash: self.sha256hash,
            path: self.path.map(|p| store_dir.parse(&p)).transpose()?,
            name: self.name,
            defaultpath: self.defaultpath,
        })
    }
}

#[derive(Debug)]
pub struct BuildProduct<'a> {
    pub r#type: &'a str,
    pub subtype: &'a str,
    pub filesize: Option<i64>,
    pub sha256hash: Option<&'a str>,
    pub path: Option<String>,
    pub name: &'a str,
    pub defaultpath: Option<&'a str>,
}

#[derive(Debug)]
pub struct OwnedBuildMetric {
    pub name: String,
    pub unit: Option<String>,
    pub value: f64,
}

#[derive(Debug)]
pub struct BuildMetric<'a> {
    pub name: &'a str,
    pub unit: Option<&'a str>,
    pub value: f64,
}

#[derive(Debug)]
pub struct MarkBuildSuccessData<'a, StorePath = harmonia_store_core::store_path::StorePath> {
    pub id: BuildID,
    pub name: &'a str,
    pub project_name: &'a str,
    pub jobset_name: &'a str,
    pub finished_in_db: bool,
    pub timestamp: i64,

    pub failed: bool,
    pub closure_size: u64,
    pub size: u64,
    pub release_name: Option<&'a str>,
    pub outputs: HashMap<OutputName, StorePath>,
    pub products: Vec<BuildProduct<'a>>,
    pub metrics: Vec<BuildMetric<'a>>,
}
