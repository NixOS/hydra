//! The `nix-eval-jobs` command line for a jobset's resolved inputs.
//!
//! Only the arguments: they describe the evaluation, so they are what the
//! dedup hash is taken over and what the evaluation build is handed to run.

use std::fmt::Write as _;

use color_eyre::eyre;
use db::StoreDir;

use crate::config::HydraConfig;
use crate::inputs::{InputInfo, JobsetInput};

/// What a jobset says to evaluate.
#[derive(Debug)]
pub(crate) struct Expression<'a> {
    /// The flake reference, when the jobset is a flake.
    pub(crate) flake: Option<&'a str>,
    /// Otherwise, the input holding the expression and the path within it.
    pub(crate) nix_expr_input: Option<&'a str>,
    pub(crate) nix_expr_path: Option<&'a str>,
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
            "boolean" | "nix" => args.extend([
                "--arg".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "eval" => {
                let jobs = alt.jobs.clone().unwrap_or_default();
                let mut s = String::from("{ ");
                for (job, path) in &jobs {
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

    let mut quoted = |key: &str, value: &Option<String>| {
        if let Some(v) = value {
            let _ = write!(s, "; {key} = \"{v}\"");
        }
    };
    quoted("uri", &input.uri);
    quoted("rev", &input.revision);
    quoted("gitTag", &input.git_tag);
    quoted("shortRev", &input.short_rev);
    quoted("version", &input.version);
    quoted("outputName", &input.output_name);

    if let Some(n) = input.rev_number {
        let _ = write!(s, "; rev = {n}");
    }
    if let Some(n) = input.rev_count {
        let _ = write!(s, "; revCount = {n}");
    }
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
        format!("{}/{path}", store_dir.to_path().display())
    }
}
