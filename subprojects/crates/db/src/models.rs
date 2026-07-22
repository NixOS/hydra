use std::collections::BTreeMap;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{ParseStorePathError, StoreDir, StorePath};
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
    /// step was resolved to a CA derivation
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
pub struct Build<StorePath = harmonia_store_path::StorePath> {
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
pub struct InsertBuildStepOutput<StorePath = harmonia_store_path::StorePath> {
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
pub(crate) struct InsertBuildProduct<'a> {
    pub build_id: BuildID,
    pub product_nr: i32,
    pub r#type: &'a str,
    pub subtype: &'a str,
    pub file_size: Option<i64>,
    pub sha256hash: Option<&'a harmonia_utils_hash::Sha256>,
    pub path: &'a str,
    pub name: &'a str,
    pub default_path: &'a str,
}

#[derive(Debug)]
pub(crate) struct InsertBuildMetric<'a> {
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

/// A build product row from the `buildproducts` table.
///
/// `buildproducts.path` is a filesystem path that may include a sub-path below
/// a store output (e.g. `doc manual $doc/share/doc/nix/manual index.html`).
/// The type parameter `Path` controls how that column is represented:
///
/// Raw DB row for build products. Column names match the SQL schema.
/// Use [`BuildProductRow::into_build_product`] to convert to the typed
/// [`nix_support::BuildProduct`].
#[derive(Debug)]
pub(crate) struct BuildProductRow {
    pub build: i32,
    pub productnr: i32,
    pub r#type: String,
    pub subtype: String,
    pub filesize: Option<i64>,
    pub sha256hash: Option<String>,
    pub path: Option<String>,
    pub name: String,
    pub defaultpath: Option<String>,
}

impl BuildProductRow {
    pub(crate) fn into_build_product(
        self,
        store_dir: &StoreDir,
    ) -> Result<nix_support::BuildProduct, crate::DataError> {
        let path_str = self.path.ok_or(crate::DataError::BuildProductMissingPath {
            build_id: self.build,
            productnr: self.productnr,
        })?;
        let path = store_path_utils::RelativeStorePath::from_path(store_dir, &path_str)?;
        let sha256hash = self.sha256hash.and_then(|s| {
            let mut bytes = [0u8; 32];
            if s.len() != 64 {
                return None;
            }
            for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
                bytes[i] = u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
            }
            harmonia_utils_hash::Sha256::from_slice(&bytes).ok()
        });
        Ok(nix_support::BuildProduct {
            path,
            default_path: self.defaultpath.unwrap_or_default(),
            r#type: self.r#type,
            subtype: self.subtype,
            name: self.name,
            is_regular: self.filesize.is_some(),
            #[allow(clippy::cast_sign_loss)]
            file_size: self.filesize.map(|v| v as u64),
            sha256hash,
        })
    }
}

#[derive(Debug)]
pub(crate) struct OwnedBuildMetric {
    pub name: String,
    pub unit: Option<String>,
    pub value: f64,
}

impl From<OwnedBuildMetric> for (nix_support::BuildMetricName, nix_support::BuildMetric) {
    fn from(m: OwnedBuildMetric) -> Self {
        (
            m.name,
            nix_support::BuildMetric {
                unit: m.unit,
                value: m.value,
            },
        )
    }
}

#[derive(Debug)]
pub struct MarkBuildSuccessData<'a, StorePath = harmonia_store_path::StorePath> {
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
    pub products: Vec<nix_support::BuildProduct>,
    pub metrics: BTreeMap<nix_support::BuildMetricName, nix_support::BuildMetric>,
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn make_row(path: Option<&str>) -> BuildProductRow {
        BuildProductRow {
            build: 1,
            productnr: 1,
            r#type: "doc".into(),
            subtype: "manual".into(),
            filesize: None,
            sha256hash: None,
            path: path.map(Into::into),
            name: "test-product".into(),
            defaultpath: Some("index.html".into()),
        }
    }

    #[test]
    fn into_build_product_subpath() {
        let store_dir = StoreDir::default();
        let bp = make_row(Some(
            "/nix/store/bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4/share/doc/nix/manual",
        ))
        .into_build_product(&store_dir)
        .unwrap();

        assert_eq!(
            bp.path.base_path.to_string(),
            "bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4"
        );
        assert_eq!(&*bp.path.relative_path, "share/doc/nix/manual");
    }

    #[test]
    fn into_build_product_bare_store_path() {
        let store_dir = StoreDir::default();
        let bp = make_row(Some(
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0",
        ))
        .into_build_product(&store_dir)
        .unwrap();

        assert_eq!(
            bp.path.base_path.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0"
        );
        assert!(bp.path.relative_path.is_empty());
    }

    #[test]
    fn into_build_product_no_path_errors() {
        let store_dir = StoreDir::default();
        let result = make_row(None).into_build_product(&store_dir);
        assert!(result.is_err());
    }

    #[test]
    fn into_build_product_sha256_roundtrip() {
        let store_dir = StoreDir::default();
        let bp = BuildProductRow {
            sha256hash: Some(
                "4306152c73d2a7a01dbac16ba48f45fa4ae5b746a1d282638524ae2ae93af210".into(),
            ),
            filesize: Some(12345),
            ..make_row(Some(
                "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0",
            ))
        }
        .into_build_product(&store_dir)
        .unwrap();

        assert!(bp.sha256hash.is_some());
        assert_eq!(bp.file_size, Some(12345));
        assert!(bp.is_regular);
    }

    #[test]
    fn build_metric_from_db() {
        let owned = OwnedBuildMetric {
            name: "closureSize".into(),
            unit: Some("bytes".into()),
            value: 145_623_040.0,
        };
        let (name, metric): (nix_support::BuildMetricName, nix_support::BuildMetric) = owned.into();
        assert_eq!(name, "closureSize");
        assert_eq!(metric.unit, Some("bytes".into()));
        assert!((metric.value - 145_623_040.0).abs() < f64::EPSILON);
    }
}
