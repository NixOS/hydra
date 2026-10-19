//! What `nix-eval-jobs` wrote, read back from the evaluation build's output.

use std::collections::BTreeMap;

use color_eyre::eyre::{self, WrapErr as _};

/// One job, as `nix-eval-jobs` reports it.
///
/// Deliberately loose: the shape of this is `nix-eval-jobs`' to define, and
/// a field we do not know about is not our business to reject.
#[derive(Debug, Clone, serde::Deserialize)]
pub(crate) struct Job {
    #[serde(default)]
    pub(crate) attr: String,
    /// The derivation's name, which is not in `meta`.
    #[serde(default)]
    pub(crate) name: Option<String>,
    #[serde(default)]
    pub(crate) error: Option<String>,
    #[serde(default, rename = "drvPath")]
    pub(crate) drv_path: Option<String>,
    /// Output name to path; a content-addressed output has no path until it
    /// is built.
    #[serde(default)]
    pub(crate) outputs: BTreeMap<String, Option<String>>,
    #[serde(default)]
    pub(crate) system: Option<String>,
    #[serde(default)]
    pub(crate) constituents: Option<Vec<String>>,
    #[serde(default)]
    pub(crate) meta: Option<serde_json::Value>,
}

/// Read the jobs out of a finished evaluation build's output.
pub(crate) fn read(path: &str) -> eyre::Result<Vec<Job>> {
    let contents = fs_err::read_to_string(path)
        .wrap_err_with(|| format!("could not read the evaluation's output at `{path}'"))?;

    let mut jobs = Vec::new();
    for line in contents.lines() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Job>(line) {
            Ok(job) => jobs.push(job),
            // A line we cannot read is worth complaining about but not worth
            // abandoning the evaluation over.
            Err(e) => tracing::warn!("nix-eval-jobs wrote unreadable JSON: {e}: {line}"),
        }
    }
    Ok(jobs)
}
