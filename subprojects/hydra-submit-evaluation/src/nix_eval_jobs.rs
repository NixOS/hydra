//! The `nix-eval-jobs` command line for a jobset's resolved inputs.
//!
//! Only the arguments, which the evaluation build is handed to run, and the
//! hash over its inputs that decides whether they were evaluated before.

use std::fmt::Write as _;

use color_eyre::eyre;
use db::StoreDir;
use sha2::{Digest as _, Sha256};

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

        let restrict_eval = if config.allow_unrestricted_eval() {
            "false"
        } else {
            "true"
        };
        cmd.extend(["--option", "restrict-eval", restrict_eval].map(str::to_owned));
        cmd.push(format!("<{input_name}/{path}>"));
        cmd.extend(inputs_to_args(store_dir, inputs)?);
    }

    cmd.extend([
        "--max-jobs".to_owned(),
        config.evaluator_max_jobs().to_string(),
    ]);
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
