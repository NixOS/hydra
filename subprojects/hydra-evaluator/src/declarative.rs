//! Declarative projects: applying the specification before `.jobsets` is
//! evaluated.
//!
//! A declarative project's jobsets come from a specification file in one of
//! its inputs, which the evaluator fetches like any other. Applying the file
//! is writing jobset rows from it, which the Perl helpers do, and
//! `hydra-notify` uses them too, so `hydra-prepare-declarative-jobset` does
//! it and reports back.

use color_eyre::eyre::{self, WrapErr as _};

#[derive(Debug, serde::Deserialize)]
struct Reply {
    declared: bool,
}

/// Apply the specification in `spec_file`. Returns whether it named the
/// jobsets outright, in which case they have been created and there is
/// nothing to evaluate; otherwise it has reconfigured `.jobsets`.
pub(crate) async fn apply(project: &str, spec_file: &str) -> eyre::Result<bool> {
    let out = tokio::process::Command::new("hydra-prepare-declarative-jobset")
        .arg(project)
        .arg(spec_file)
        .output()
        .await
        .wrap_err("failed to run hydra-prepare-declarative-jobset")?;
    let stderr = String::from_utf8(out.stderr)
        .wrap_err("hydra-prepare-declarative-jobset wrote non-UTF-8 to stderr")?;
    if !out.status.success() {
        eyre::bail!("hydra-prepare-declarative-jobset failed:\n{stderr}");
    }
    // Even on success, stderr can report jobsets that failed to apply.
    if !stderr.trim().is_empty() {
        tracing::warn!("hydra-prepare-declarative-jobset: {}", stderr.trim_end());
    }

    let reply: Reply = serde_json::from_slice(&out.stdout)
        .wrap_err("hydra-prepare-declarative-jobset sent an unreadable reply")?;
    Ok(reply.declared)
}
