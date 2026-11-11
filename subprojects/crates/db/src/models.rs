use std::collections::BTreeMap;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_utils_hash::fmt::{Bare, Base16};

pub type BuildID = i32;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
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
pub struct Build {
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
    pub timestamp: crate::Timestamp,
    pub globalpriority: i32,
    pub priority: i32,
}

#[derive(Debug, Clone, Copy)]
pub struct BuildSteps {
    pub starttime: Option<crate::Timestamp>,
    pub stoptime: Option<crate::Timestamp>,
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BuildType {
    Build = 0,
    Substitution = 1,
}

#[derive(Debug)]
pub(crate) struct UpdateBuild<'a> {
    pub status: BuildStatus,
    pub start_time: crate::Timestamp,
    pub stop_time: crate::Timestamp,
    pub size: i64,
    pub closure_size: i64,
    pub release_name: Option<&'a str>,
    pub is_cached_build: bool,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct InsertBuildStep<'a> {
    pub build_id: BuildID,
    pub r#type: BuildType,
    pub drv_path: &'a StorePath,
    /// [`Busy`](BuildStatus::Busy) marks the step busy and leaves its status unset.
    pub status: BuildStatus,
    pub start_time: Option<crate::Timestamp>,
    pub stop_time: Option<crate::Timestamp>,
    pub platform: Option<&'a str>,
    pub propagated_from: Option<BuildID>,
    pub error_msg: Option<&'a str>,
    pub machine: &'a str,
    /// Set if and only if `status` is [`Resolved`](BuildStatus::Resolved).
    /// A check constraint on `buildsteps` enforces this.
    pub resolved_drv_path: Option<&'a StorePath>,
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
    pub start_time: crate::Timestamp,
    pub stop_time: crate::Timestamp,
    pub machine: Option<&'a str>,
    pub overhead: Option<i32>,
    pub times_built: Option<i32>,
    pub is_non_deterministic: Option<bool>,
}

#[derive(Debug)]
pub struct BuildOutput {
    pub id: BuildID,
    pub buildstatus: BuildStatus,
    pub releasename: Option<String>,
    pub closuresize: Option<i64>,
    pub size: Option<i64>,
}

/// Raw DB row for build products. Column names match the SQL schema.
///
/// A build product can name something *inside* a store output (e.g. `doc
/// manual $doc/share/doc/nix/manual index.html`), so unlike other store-path
/// columns it takes two: `path` for the store path and `subpath` for the rest.
///
/// Use [`BuildProductRow::into_build_product`] to convert to the typed
/// [`nix_support::BuildProduct`].
#[derive(Debug)]
pub(crate) struct BuildProductRow {
    pub build: BuildID,
    pub productnr: i32,
    pub r#type: String,
    pub subtype: String,
    pub filesize: Option<i64>,
    pub sha256hash: Option<String>,
    pub path: Option<String>,
    pub subpath: Option<String>,
    pub storedir: Option<String>,
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
        // A row that `hydra-backfill-store-dirs` has not converted yet still
        // holds both halves run together in `path`, with a null `subpath`.
        let path = match self.subpath {
            Some(sub_path) => store_path_utils::RelativeStorePath {
                base_path: StorePath::from_base_path(&path_str)?,
                relative_path: sub_path.into(),
            },
            None => store_path_utils::RelativeStorePath::from_path(store_dir, &path_str)?,
        };
        let sha256hash = self.sha256hash.and_then(|s| {
            s.parse::<Bare<Base16<harmonia_utils_hash::Sha256>>>()
                .ok()
                .map(Into::into)
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
pub struct MarkBuildSuccessData<'a> {
    pub id: BuildID,
    pub name: &'a str,
    pub project_name: &'a str,
    pub jobset_name: &'a str,
    pub finished_in_db: bool,
    pub timestamp: crate::Timestamp,

    pub failed: bool,
    pub closure_size: u64,
    pub size: u64,
    pub release_name: Option<&'a str>,
    pub outputs: &'a BTreeMap<OutputName, StorePath>,
    pub products: &'a [nix_support::BuildProduct],
    pub metrics: &'a BTreeMap<nix_support::BuildMetricName, nix_support::BuildMetric>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A converted row: the store path in `path`, the rest in `subpath`.
    fn make_row_with_sub_path(path: Option<&str>, sub_path: &str) -> BuildProductRow {
        BuildProductRow {
            subpath: path.map(|_| sub_path.into()),
            ..make_row(path)
        }
    }

    /// A row `hydra-backfill-store-dirs` has not reached: both halves run
    /// together in `path`, and no `subpath` or `storeDir`.
    fn make_row(path: Option<&str>) -> BuildProductRow {
        BuildProductRow {
            build: 1,
            productnr: 1,
            r#type: "doc".into(),
            subtype: "manual".into(),
            filesize: None,
            sha256hash: None,
            path: path.map(Into::into),
            subpath: None,
            storedir: None,
            name: "test-product".into(),
            defaultpath: Some("index.html".into()),
        }
    }

    #[test]
    fn into_build_product_subpath() {
        let bp = make_row_with_sub_path(
            Some("bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4"),
            "share/doc/nix/manual",
        )
        .into_build_product(&StoreDir::default())
        .unwrap();

        assert_eq!(
            bp.path.base_path.to_string(),
            "bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4"
        );
        assert_eq!(&*bp.path.relative_path, "share/doc/nix/manual");
    }

    #[test]
    fn into_build_product_bare_store_path() {
        let bp = make_row_with_sub_path(Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0"), "")
            .into_build_product(&StoreDir::default())
            .unwrap();

        assert_eq!(
            bp.path.base_path.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0"
        );
        assert!(bp.path.relative_path.is_empty());
    }

    /// An unconverted row still has to read back the same way.
    #[test]
    fn into_build_product_unconverted() {
        let bp = make_row(Some(
            "/nix/store/bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4/share/doc/nix/manual",
        ))
        .into_build_product(&StoreDir::default())
        .unwrap();

        assert_eq!(
            bp.path.base_path.to_string(),
            "bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4"
        );
        assert_eq!(&*bp.path.relative_path, "share/doc/nix/manual");
    }

    #[test]
    fn into_build_product_no_path_errors() {
        let result = make_row(None).into_build_product(&StoreDir::default());
        assert!(result.is_err());
    }

    #[test]
    fn into_build_product_sha256_roundtrip() {
        let bp = BuildProductRow {
            sha256hash: Some(
                "4306152c73d2a7a01dbac16ba48f45fa4ae5b746a1d282638524ae2ae93af210".into(),
            ),
            filesize: Some(12345),
            ..make_row_with_sub_path(Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0"), "")
        }
        .into_build_product(&StoreDir::default())
        .unwrap();

        assert!(bp.sha256hash.is_some());
        assert_eq!(bp.file_size, Some(12345));
        assert!(bp.is_regular);
    }
}
