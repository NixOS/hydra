//! Resolving a jobset's inputs.
//!
//! Most input types are ours: `build`, `sysbuild` and `eval` are queries
//! against tables this process owns, and `string`, `nix` and `boolean` are
//! literals. Everything else is a plugin type, and goes to the Perl worker --
//! see [`crate::fetcher`].
//!
//! The result is what the evaluator needs to describe the evaluation: one
//! entry per input name, each with the alternatives that input produced.

use std::collections::BTreeMap;

use color_eyre::eyre::{self, WrapErr as _};

use crate::fetcher::InputFetcher;
use crate::queries;
use crate::queries::InputBuild;
use crate::store_paths::Availability;

/// One resolved alternative of one input.
///
/// The field names are the ones the Perl used, because they are also the
/// names that reach the Nix expression as attributes of the input -- `rev`,
/// `revCount`, `shortRev` and the rest are a jobset-visible interface, not an
/// internal detail, so renaming them would be a breaking change.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JobsetInput {
    /// The input's type, filled in by whoever resolved it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub r#type: Option<String>,

    /// The store path this input resolved to, if it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_path: Option<String>,

    /// For `string`, `nix` and `boolean` inputs, the literal value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev_number: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub short_rev: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256hash: Option<String>,

    /// Set for `build` and `sysbuild` inputs: which build this came from,
    /// and how to describe it to the expression.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drv_path: Option<String>,

    /// Set for `eval` inputs: the jobs of the evaluation, by name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jobs: Option<BTreeMap<String, String>>,

    /// Whether whoever owns this input should be told when it breaks.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub email_responsible: bool,
}

/// A jobset's inputs, by name, each with its alternatives.
pub(crate) type InputInfo = BTreeMap<String, Vec<JobsetInput>>;

/// How an input is configured: what the jobset says, before resolution.
#[derive(Debug)]
pub(crate) struct ConfiguredInput {
    pub name: String,
    pub r#type: String,
    pub value: Option<String>,
    pub email_responsible: bool,
}

/// Resolve every input of a jobset.
///
/// An input that cannot be resolved is fatal, as it was before: an
/// evaluation missing one of its inputs is not an evaluation of anything.
pub(crate) async fn resolve(
    conn: &mut db::Connection,
    fetcher: &mut InputFetcher,
    available: &Availability,
    project: &str,
    jobset: &str,
    configured: &[ConfiguredInput],
) -> eyre::Result<InputInfo> {
    let mut info = InputInfo::new();

    for input in configured {
        tracing::info!(
            "({project}:{jobset}) fetching input `{}` ({}) {}",
            input.name,
            input.r#type,
            input.value.as_deref().unwrap_or("")
        );

        let mut alternatives = resolve_one(conn, fetcher, available, project, jobset, input)
            .await
            .wrap_err_with(|| format!("failed to fetch input `{}`", input.name))?;

        // Both of these are properties of how the input was configured
        // rather than of what fetching it produced, so they are set here
        // instead of by each resolver.
        for alt in &mut alternatives {
            alt.r#type = Some(input.r#type.clone());
            alt.email_responsible = input.email_responsible;
        }

        info.entry(input.name.clone())
            .or_default()
            .extend(alternatives);
    }

    Ok(info)
}

async fn resolve_one(
    conn: &mut db::Connection,
    fetcher: &mut InputFetcher,
    available: &Availability,
    project: &str,
    jobset: &str,
    input: &ConfiguredInput,
) -> eyre::Result<Vec<JobsetInput>> {
    match input.r#type.as_str() {
        "string" | "nix" => {
            let value = input
                .value
                .clone()
                .ok_or_else(|| eyre::eyre!("a `{}` input needs a value", input.r#type))?;
            Ok(vec![JobsetInput {
                value: Some(value),
                ..Default::default()
            }])
        }

        "boolean" => {
            let value = input.value.as_deref().unwrap_or_default();
            eyre::ensure!(
                value == "true" || value == "false",
                "a `boolean` input must be `true` or `false`, not `{value}`"
            );
            Ok(vec![JobsetInput {
                value: Some(value.to_owned()),
                ..Default::default()
            }])
        }

        "build" => {
            let value = input
                .value
                .as_deref()
                .ok_or_else(|| eyre::eyre!("a `build` input needs a value"))?;
            resolve_build(conn, available, project, jobset, value).await
        }

        "sysbuild" => {
            let value = input
                .value
                .as_deref()
                .ok_or_else(|| eyre::eyre!("a `sysbuild` input needs a value"))?;
            let (p, j, job) = split_job_name(project, jobset, value);
            let builds = queries::get_latest_succeeded_build_per_system(conn, &p, &j, &job).await?;
            let mut usable = Vec::new();
            for build in &builds {
                if let Some(path) = &build.out_path
                    && available.is_available(path).await
                {
                    usable.push(from_build(build));
                }
            }
            if usable.is_empty() {
                tracing::info!("input `{}': no previous build available", input.name);
            }
            Ok(usable)
        }

        "eval" => {
            let value = input
                .value
                .as_deref()
                .ok_or_else(|| eyre::eyre!("an `eval` input needs a value"))?;
            resolve_eval(conn, value).await
        }

        _ => {
            // Plugin territory.
            fetcher
                .fetch(
                    &input.r#type,
                    &input.name,
                    input.value.as_deref(),
                    project,
                    jobset,
                )
                .await
        }
    }
}

/// A `build` input names either a build by number, or a job whose most
/// recent successful build is wanted.
async fn resolve_build(
    conn: &mut db::Connection,
    available: &Availability,
    project: &str,
    jobset: &str,
    value: &str,
) -> eyre::Result<Vec<JobsetInput>> {
    let build = if let Ok(id) = value.parse::<i32>() {
        queries::get_build_for_input_by_id(conn, id).await?
    } else {
        let (p, j, job) = split_job_name(project, jobset, value);
        queries::get_latest_succeeded_build(conn, &p, &j, &job).await?
    };

    // No build, or one whose output is not in the store, is not an error: it
    // means this input has nothing to contribute yet. The output has to be
    // there and not merely recorded, since the expression is handed it as a
    // `builtins.storePath`.
    Ok(match build {
        Some(build) => match &build.out_path {
            Some(path) if available.is_available(path).await => vec![from_build(&build)],
            _ => vec![],
        },
        None => vec![],
    })
}

/// An `eval` input names an evaluation, and contributes its successful jobs
/// to the expression as an attribute set of store paths.
///
/// Unlike a `build` input, failing to find one is fatal: the value named an
/// evaluation and there isn't one, which is a mistake rather than a state
/// the jobset can evaluate its way out of.
async fn resolve_eval(conn: &mut db::Connection, value: &str) -> eyre::Result<Vec<JobsetInput>> {
    let parts: Vec<&str> = value.split(':').collect();
    let eval = match (value.parse::<i32>(), parts.as_slice()) {
        (Ok(id), _) => queries::get_eval_by_id(conn, id)
            .await?
            .ok_or_else(|| eyre::eyre!("evaluation {id} does not exist"))?,
        (_, [project, jobset]) => queries::get_latest_finished_eval(conn, project, jobset)
            .await?
            .ok_or_else(|| eyre::eyre!("jobset `{value}' does not have a finished evaluation"))?,
        (_, [project, jobset, job]) => {
            queries::get_latest_finished_eval_with_job(conn, project, jobset, job)
                .await?
                .ok_or_else(|| {
                    eyre::eyre!(
                        "there is no successful build of `{value}' in a finished evaluation"
                    )
                })?
        }
        _ => eyre::bail!("`{value}' does not name an evaluation"),
    };

    Ok(vec![JobsetInput {
        jobs: Some(
            queries::get_eval_jobs(conn, eval)
                .await?
                .into_iter()
                .collect(),
        ),
        ..Default::default()
    }])
}

/// `project:jobset:job`, with either of the first two defaulting to the
/// jobset being evaluated.
fn split_job_name(project: &str, jobset: &str, value: &str) -> (String, String, String) {
    let parts: Vec<&str> = value.split(':').collect();
    match parts.as_slice() {
        [p, j, job] => ((*p).to_owned(), (*j).to_owned(), (*job).to_owned()),
        [j, job] => (project.to_owned(), (*j).to_owned(), (*job).to_owned()),
        _ => (project.to_owned(), jobset.to_owned(), value.to_owned()),
    }
}

/// Describe a build to the Nix expression the way the Perl did.
fn from_build(build: &InputBuild) -> JobsetInput {
    JobsetInput {
        store_path: build.out_path.clone(),
        id: Some(build.id),
        version: version_of(build),
        output_name: build.out_name.clone(),
        ..Default::default()
    }
}

/// The version part of a `name-version` release name, if it looks like one.
///
/// The pattern is the Perl's: a name of alphanumerics and hyphens that are
/// not followed by a digit, then a hyphen, then the version.
fn version_of(build: &InputBuild) -> Option<String> {
    let name = build.releasename.as_ref().or(build.nixname.as_ref())?;
    let (prefix, version) = name.rsplit_once('-')?;
    if prefix.is_empty() || version.is_empty() {
        return None;
    }
    version
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
        .then(|| version.to_owned())
}
