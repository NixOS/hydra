//! Running `nix-eval-jobs` over a jobset's resolved inputs.
//!
//! The arguments describe the evaluation, so they are built separately from
//! running it.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::process::Stdio;

use color_eyre::eyre::{self, WrapErr as _};
use db::StoreDir;
use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncBufReadExt as _, BufReader};

use crate::config::HydraConfig;
use crate::inputs::{InputInfo, JobsetInput};

/// What a jobset says to evaluate.
#[derive(Debug)]
pub(crate) struct Expression<'a> {
    /// The flake reference, when the jobset is a flake.
    pub flake: Option<&'a str>,
    /// Otherwise, the input holding the expression and the path within it.
    pub nix_expr_input: Option<&'a str>,
    pub nix_expr_path: Option<&'a str>,
}

/// One job, as `nix-eval-jobs` reports it.
///
/// Deliberately loose: the shape of this is `nix-eval-jobs`' to define, and
/// a field we do not know about is not our business to reject.
#[derive(Debug, serde::Deserialize)]
pub(crate) struct Job {
    #[serde(default)]
    pub attr: String,
    /// The derivation's name, which is not in `meta`.
    pub name: Option<String>,
    pub error: Option<String>,
    #[serde(rename = "drvPath")]
    pub drv_path: Option<String>,
    /// Output name to path; a content-addressed output has no path until it
    /// is built.
    #[serde(default)]
    pub outputs: BTreeMap<String, Option<String>>,
    pub system: Option<String>,
    pub constituents: Option<Vec<String>>,
    pub meta: Option<serde_json::Value>,
}

/// Assemble the `nix-eval-jobs` command line for a jobset.
pub(crate) fn command(
    store_dir: &StoreDir,
    config: &HydraConfig,
    inputs: &InputInfo,
    expr: &Expression<'_>,
) -> eyre::Result<Vec<String>> {
    let mut cmd: Vec<String> = Vec::new();

    if let Some(flake) = expr.flake {
        // The eval cache is off deliberately: Hydra evaluates a given
        // revision about once, so parallel workers would contend for the
        // SQLite lock and get nothing back for it.
        cmd.extend(
            [
                "--option",
                "eval-cache",
                "false",
                "--flake",
                flake,
                "--select",
                "flake: flake.outputs.hydraJobs or flake.outputs.checks or (throw \"flake does not provide any Hydra jobs or checks\")",
            ]
            .map(str::to_owned),
        );
    } else {
        let input_name = expr
            .nix_expr_input
            .ok_or_else(|| eyre::eyre!("the jobset has neither a flake nor an expression"))?;
        let path = expr.nix_expr_path.unwrap_or_default();
        eyre::ensure!(
            inputs.contains_key(input_name),
            "cannot find the input containing the job expression"
        );

        let restrict_eval = if config.allow_unrestricted_eval() {
            "false"
        } else {
            "true"
        };
        cmd.extend(["--option", "restrict-eval", restrict_eval].map(str::to_owned));
        cmd.push(format!("<{input_name}/{path}>"));
        cmd.extend(inputs_to_args(store_dir, inputs)?);
    }

    cmd.extend(["--max-jobs", "1"].map(str::to_owned));
    cmd.push("--meta".to_owned());
    cmd.push("--constituents".to_owned());
    cmd.push("--force-recurse".to_owned());
    if !config.allow_import_from_derivation() {
        cmd.extend(["--option", "allow-import-from-derivation", "false"].map(str::to_owned));
    }
    cmd.extend([
        "--workers".to_owned(),
        config.evaluator_workers().to_string(),
    ]);
    cmd.extend([
        "--max-memory-size".to_owned(),
        config.evaluator_max_memory_size().to_string(),
    ]);

    Ok(cmd)
}

/// The hash that decides whether these inputs were evaluated before. It
/// covers the expression and the input arguments and is computed exactly as
/// the Perl did, so evaluations the Perl recorded still count. Flakes are
/// compared separately, by their locked reference.
pub(crate) fn input_hash(
    store_dir: &StoreDir,
    inputs: &InputInfo,
    expr: &Expression<'_>,
) -> eyre::Result<String> {
    let mut args = vec![
        expr.nix_expr_input.unwrap_or_default().to_owned(),
        expr.nix_expr_path.unwrap_or_default().to_owned(),
    ];
    args.extend(inputs_to_args(store_dir, inputs)?);
    Ok(hex::encode(Sha256::digest(args.join(" ").as_bytes())))
}

/// Turn the resolved inputs into the arguments that make them visible to the
/// expression.
fn inputs_to_args(store_dir: &StoreDir, inputs: &InputInfo) -> eyre::Result<Vec<String>> {
    let mut args = Vec::new();

    for (name, alts) in inputs {
        // A `build` input whose job has never been built resolves to
        // nothing, and the expression is left to default it.
        let [alt] = alts.as_slice() else {
            eyre::ensure!(
                alts.is_empty(),
                "multiple jobset input alternatives are no longer supported"
            );
            continue;
        };

        if let Some(path) = &alt.store_path {
            args.extend(["-I".to_owned(), format!("{name}={}", full(store_dir, path))]);
        }

        match alt.r#type.as_deref().unwrap_or_default() {
            "string" => args.extend([
                "--argstr".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "boolean" | "nix" => args.extend([
                "--arg".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "eval" => {
                let mut s = String::from("{ ");
                for (job, path) in alt.jobs.iter().flatten() {
                    let _ = write!(s, "{job} = builtins.storePath {}; ", full(store_dir, path));
                }
                s.push('}');
                args.extend(["--arg".to_owned(), name.clone(), s]);
            }
            _ => args.extend([
                "--arg".to_owned(),
                name.clone(),
                build_input_to_string(store_dir, alt),
            ]),
        }
    }

    Ok(args)
}

/// Describe a fetched input to the expression.
///
/// The attribute names here are a jobset-visible interface -- expressions
/// read `rev`, `revCount`, `shortRev` and the rest -- so they are not ours
/// to rename.
fn build_input_to_string(store_dir: &StoreDir, input: &JobsetInput) -> String {
    let mut s = String::from("{ outPath = builtins.storePath ");
    s.push_str(&full(store_dir, input.store_path.as_deref().unwrap_or("")));
    let _ = write!(
        s,
        "; inputType = \"{}\"",
        input.r#type.as_deref().unwrap_or("")
    );

    // In the Perl's order, which the input hash depends on.
    let quoted = |s: &mut String, key: &str, value: &Option<String>| {
        if let Some(v) = value {
            let _ = write!(s, "; {key} = \"{v}\"");
        }
    };
    quoted(&mut s, "uri", &input.uri);
    if let Some(n) = input.rev_number {
        let _ = write!(s, "; rev = {n}");
    }
    quoted(&mut s, "rev", &input.revision);
    if let Some(n) = input.rev_count {
        let _ = write!(s, "; revCount = {n}");
    }
    quoted(&mut s, "gitTag", &input.git_tag);
    quoted(&mut s, "shortRev", &input.short_rev);
    quoted(&mut s, "version", &input.version);
    quoted(&mut s, "outputName", &input.output_name);
    if let Some(drv) = &input.drv_path {
        let _ = write!(s, "; drvPath = builtins.storePath {}", full(store_dir, drv));
    }

    s.push_str(";}");
    s
}

/// A store path as a full path, which is what Nix takes -- `builtins.storePath`,
/// `-I`, `nix copy`. Hydra keeps store paths as bare names, mostly.
pub(crate) fn full(store_dir: &StoreDir, path: &str) -> String {
    if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("{store_dir}/{path}")
    }
}

/// Run `nix-eval-jobs` and hand back the jobs it reports.
///
/// It roots each derivation in `gc_roots_dir` as it goes, so the garbage
/// collector cannot delete one before the builds that need it are queued.
///
/// Its stderr is logged at debug, and its tail ends up in the error if it
/// fails, so the jobset shows why.
pub(crate) async fn run(cmd: &[String], gc_roots_dir: &std::path::Path) -> eyre::Result<Vec<Job>> {
    // NIX_PATH is cleared so that an evaluation depends on its declared
    // inputs and nothing about the machine it runs on.
    let mut child = tokio::process::Command::new("nix-eval-jobs")
        .args(cmd)
        .arg("--gc-roots-dir")
        .arg(gc_roots_dir)
        .env_remove("NIX_PATH")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .wrap_err("failed to start nix-eval-jobs")?;

    let stderr_tail = crate::forward_stderr("nix-eval-jobs", &mut child)?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| eyre::eyre!("nix-eval-jobs has no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();

    let mut jobs = Vec::new();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Job>(&line) {
            Ok(job) => jobs.push(job),
            // A line we cannot read is worth complaining about but not worth
            // abandoning the evaluation over, which is what the Perl did.
            Err(e) => tracing::warn!("nix-eval-jobs sent unreadable JSON: {e}: {line}"),
        }
    }

    let status = child.wait().await?;
    if !status.success() {
        let tail = stderr_tail.await.unwrap_or_default();
        if tail.is_empty() {
            eyre::bail!("nix-eval-jobs failed: {status}");
        }
        eyre::bail!("nix-eval-jobs failed: {status}\n{tail}");
    }

    Ok(jobs)
}
