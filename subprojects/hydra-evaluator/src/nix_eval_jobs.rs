//! Running `nix-eval-jobs` over a jobset's resolved inputs.
//!
//! The arguments describe the evaluation, so they are built separately from
//! running it: the same description is what the dedup hash is taken over, and
//! what would be handed to something else to run.

use std::collections::BTreeMap;
use std::process::Stdio;

use color_eyre::eyre::{self, WrapErr as _};
use db::StoreDir;
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
#[derive(Debug, Clone, serde::Deserialize)]
pub(crate) struct Job {
    #[serde(default)]
    pub attr: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default, rename = "drvPath")]
    pub drv_path: Option<String>,
    #[serde(default)]
    pub outputs: BTreeMap<String, String>,
    #[serde(default)]
    pub system: Option<String>,
    #[serde(default)]
    pub constituents: Option<Vec<String>>,
    #[serde(default)]
    pub meta: Option<serde_json::Value>,
}

/// Assemble the `nix-eval-jobs` command line for a jobset.
///
/// Separate from running it because the arguments describe the evaluation
/// regardless of who performs it: they are also what the deduplication hash
/// is computed over.
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

        cmd.extend(["--option", "restrict-eval", "true"].map(str::to_owned));
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

/// Turn the resolved inputs into the arguments that make them visible to the
/// expression.
fn inputs_to_args(store_dir: &StoreDir, inputs: &InputInfo) -> eyre::Result<Vec<String>> {
    let mut args = Vec::new();

    for (name, alts) in inputs {
        eyre::ensure!(
            alts.len() == 1,
            "multiple jobset input alternatives are no longer supported"
        );
        let alt = &alts[0];

        if let Some(path) = &alt.store_path {
            args.extend(["-I".to_owned(), format!("{name}={}", full(store_dir, path))]);
        }

        match alt.r#type.as_deref().unwrap_or_default() {
            "string" => args.extend([
                "--argstr".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "boolean" => args.extend([
                "--arg".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "nix" => args.extend([
                "--arg".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "eval" => {
                let jobs = alt.jobs.clone().unwrap_or_default();
                let mut s = String::from("{ ");
                for (job, path) in &jobs {
                    s.push_str(&format!(
                        "{job} = builtins.storePath {}; ",
                        full(store_dir, path)
                    ));
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
    s.push_str(&format!(
        "; inputType = \"{}\"",
        input.r#type.as_deref().unwrap_or("")
    ));

    let mut quoted = |key: &str, value: &Option<String>| {
        if let Some(v) = value {
            s.push_str(&format!("; {key} = \"{v}\""));
        }
    };
    quoted("uri", &input.uri);
    quoted("rev", &input.revision);
    quoted("gitTag", &input.git_tag);
    quoted("shortRev", &input.short_rev);
    quoted("version", &input.version);
    quoted("outputName", &input.output_name);

    if let Some(n) = input.rev_number {
        s.push_str(&format!("; rev = {n}"));
    }
    if let Some(n) = input.rev_count {
        s.push_str(&format!("; revCount = {n}"));
    }
    if let Some(drv) = &input.drv_path {
        s.push_str(&format!(
            "; drvPath = builtins.storePath {}",
            full(store_dir, drv)
        ));
    }

    s.push_str(";}");
    s
}

/// `builtins.storePath` and `-I` take a full path: that is Nix's vocabulary,
/// not Hydra's, which keeps store paths as bare names.
fn full(store_dir: &StoreDir, path: &str) -> String {
    if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("{}/{path}", store_dir.to_path().display())
    }
}

/// Run `nix-eval-jobs` and hand back the jobs it reports, one at a time.
///
/// Its stderr is inherited: diagnostics are how an evaluation explains
/// itself, and they belong in the log rather than buffered up here.
pub(crate) async fn run(cmd: &[String]) -> eyre::Result<Vec<Job>> {
    // NIX_PATH is cleared so that an evaluation depends on its declared
    // inputs and nothing about the machine it runs on.
    let mut child = tokio::process::Command::new("nix-eval-jobs")
        .args(cmd)
        .env_remove("NIX_PATH")
        .stdout(Stdio::piped())
        .spawn()
        .wrap_err("failed to start nix-eval-jobs")?;

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
    eyre::ensure!(status.success(), "nix-eval-jobs failed: {status}");

    Ok(jobs)
}
