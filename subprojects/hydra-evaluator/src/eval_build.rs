//! Turning an evaluation into a derivation that performs it.
//!
//! `nix_eval_jobs::command` says what to run; this wraps that command in a
//! derivation so it can be queued as an ordinary build. The evaluation then
//! gets sandboxing, timeouts, retries, logs and distribution from the build
//! system rather than from the evaluator.
//!
//! Nothing here evaluates the jobset. `nix-instantiate` is handed a couple of
//! dozen generated lines describing one derivation; the jobset's own
//! expression is evaluated later, by `nix-eval-jobs`, inside the build.

use color_eyre::eyre::{self, WrapErr as _};

use crate::config::HydraConfig;
use crate::inputs::InputInfo;

/// Quote a string as Nix source.
fn nix_string(s: &str) -> String {
    let escaped = s
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
        .replace('\n', "\\n");
    format!("\"{escaped}\"")
}

/// The store paths an evaluation reads, so the build references them rather
/// than merely mentioning them.
fn input_store_paths(inputs: &InputInfo) -> Vec<String> {
    let mut paths = Vec::new();
    for alts in inputs.values() {
        for alt in alts {
            if let Some(path) = &alt.store_path {
                paths.push(path.clone());
            }
            if let Some(jobs) = &alt.jobs {
                paths.extend(jobs.values().cloned());
            }
        }
    }
    paths
}

/// The expression whose one derivation runs the evaluation.
fn expression(
    name: &str,
    store_paths: &[String],
    cmd: &[String],
    system_features: &[String],
    store_dir: &str,
    store_uri: Option<&str>,
    nix_config: Option<&str>,
) -> String {
    let sanitised: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();

    // `"$@"` rather than a quoted command line: the arguments stay separate
    // Nix strings, so Nix's escaping is the only escaping involved.
    //
    // `HOME` is unset in a build, and Nix's own default of /homeless-shelter
    // is not writable, so the evaluator cannot open its eval cache. Point it
    // at the build directory, which is writable and discarded afterwards.
    let script = r#"set -eu; export HOME="$PWD"; "$@" > "$out""#;

    let mut argv = vec!["-c".to_owned(), script.to_owned(), "hydra-eval".to_owned()];
    argv.extend(cmd.iter().cloned());

    let args = argv
        .iter()
        .map(|a| nix_string(a))
        .collect::<Vec<_>>()
        .join(" ");
    let inputs = store_paths
        .iter()
        .map(|p| format!("(builtins.storePath {})", nix_string(p)))
        .collect::<Vec<_>>()
        .join(" ");

    let mut expr = String::from("derivation {\n");
    expr.push_str(&format!(
        "  name = {};\n",
        nix_string(&format!("hydra-eval-{sanitised}"))
    ));
    expr.push_str("  system = builtins.currentSystem;\n");
    expr.push_str("  builder = \"/bin/sh\";\n");
    expr.push_str(&format!("  args = [ {args} ];\n"));
    // What evaluation needs from the machine is the ability to add paths to
    // the store while it builds, since instantiating is what evaluating does.
    // Under a sandbox that means `recursive-nix`; an unsandboxed build with a
    // writable store already has it, and asking for the feature there only
    // forces a sandbox that cannot be used.
    if !system_features.is_empty() {
        let features = system_features
            .iter()
            .map(|f| nix_string(f))
            .collect::<Vec<_>>()
            .join(" ");
        expr.push_str(&format!("  requiredSystemFeatures = [ {features} ];\n"));
    }

    // Which store the evaluation instantiates into. A build gets no
    // `NIX_STORE_DIR`, so a nested Nix falls back to the compile-time
    // `/nix/store` -- and then rejects Hydra's own inputs as "not in the Nix
    // store" whenever Hydra's store is relocated. The logical store dir is
    // the same on every machine Hydra talks to, so naming it here is
    // machine-independent despite looking like a local detail.
    expr.push_str(&format!("  NIX_STORE_DIR = {};\n", nix_string(store_dir)));

    // That alone is not always enough. A nested Nix with no `NIX_REMOTE`
    // resolves `auto`, and an *unsandboxed* build can see the host's real
    // daemon socket -- whose store dir then wins over the setting above. So
    // when there is no `recursive-nix` to configure the build's Nix for us,
    // the store has to be named outright. It must be the builder's store, so
    // this is configuration rather than anything derivable here.
    if let Some(uri) = store_uri.filter(|u| !u.is_empty()) {
        expr.push_str(&format!("  NIX_REMOTE = {};\n", nix_string(uri)));
    }

    // Nix settings the evaluation needs, chiefly which experimental features
    // are on: a flake jobset cannot be evaluated without `flakes`, and a
    // content-addressed one without `ca-derivations`. Evaluation used to
    // inherit these from the Hydra host's `nix.conf`; inside a build there is
    // no such file, so they have to be carried in. Part of the derivation,
    // and so of its hash, which is right -- the same expression evaluated
    // with different settings is not the same evaluation.
    if let Some(config) = nix_config.filter(|c| !c.is_empty()) {
        expr.push_str(&format!("  NIX_CONFIG = {};\n", nix_string(config)));
    }

    // Referenced so the inputs are inputs of this derivation, and so appear
    // in the sandbox rather than merely being named by the arguments.
    expr.push_str(&format!("  jobsetInputs = [ {inputs} ];\n"));
    expr.push_str("}\n");
    expr
}

/// Instantiate the derivation that will perform this evaluation.
pub(crate) async fn instantiate(
    config: &HydraConfig,
    inputs: &InputInfo,
    cmd: &[String],
    jobset_name: &str,
    store_dir: &str,
) -> eyre::Result<String> {
    let mut store_paths = input_store_paths(inputs);

    // A build does not inherit PATH, so the evaluator has to be named by its
    // absolute path. Reference it too when it is in this store, so that it
    // and its closure are in the sandbox rather than merely mentioned -- but
    // only then: Hydra's store is not always the ambient one, and a path from
    // another store is not a store path here.
    let mut cmd = cmd.to_vec();
    if let Some(evaluator) = which(&cmd[0]) {
        if let Some(root) = store_path_root(&evaluator, store_dir) {
            store_paths.push(root);
        }
        cmd[0] = evaluator;
    }

    let features: Vec<String> = config
        .evaluation_build_system_features()
        .split_whitespace()
        .map(str::to_owned)
        .collect();

    let nix_config = evaluation_nix_config().await?;

    let expr = expression(
        jobset_name,
        &store_paths,
        &cmd,
        &features,
        store_dir,
        config.evaluation_build_store_uri(),
        nix_config.as_deref(),
    );

    if std::env::var("HYDRA_DEBUG").is_ok() {
        tracing::info!("evaluation derivation:\n{expr}");
    }

    // stdout and stderr are kept apart: `nix-instantiate` prints warnings,
    // and folding those into the captured path corrupts it.
    let out = tokio::process::Command::new("nix-instantiate")
        .arg("--expr")
        .arg(&expr)
        .output()
        .await
        .wrap_err("could not run nix-instantiate")?;

    eyre::ensure!(
        out.status.success(),
        "instantiating the evaluation derivation failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );

    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// The first `PATH` entry that holds an executable of this name.
fn which(name: &str) -> Option<String> {
    if name.contains('/') {
        return Some(name.to_owned());
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

/// The store path a file belongs to, if it is in this store.
fn store_path_root(path: &str, store_dir: &str) -> Option<String> {
    let rest = path.strip_prefix(store_dir)?.strip_prefix('/')?;
    let name = rest.split('/').next()?;
    (!name.is_empty()).then(|| format!("{store_dir}/{name}"))
}

/// The Nix settings an evaluation needs, as a `NIX_CONFIG` value.
///
/// Chiefly which experimental features are on: a flake jobset cannot be
/// evaluated without `flakes`, and a content-addressed one without
/// `ca-derivations`. Evaluation used to inherit these from the Hydra host's
/// `nix.conf`; inside a build there is no such file, so they are carried in.
async fn evaluation_nix_config() -> eyre::Result<Option<String>> {
    let out = tokio::process::Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command",
            "config",
            "show",
            "experimental-features",
        ])
        .output()
        .await
        .wrap_err("could not read the evaluator's experimental features")?;

    eyre::ensure!(
        out.status.success(),
        "could not read the evaluator's experimental features:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let features = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    Ok((!features.is_empty()).then(|| format!("experimental-features = {features}")))
}
