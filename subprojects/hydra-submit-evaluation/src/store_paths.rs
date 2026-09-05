//! Making sure a build's output is there before an evaluation is told about it.
//!
//! A `build` or `sysbuild` input names a previous build, and the expression is
//! handed its output as `builtins.storePath`. That only works if the path is
//! actually in the store: it may have been garbage collected, or -- where the
//! evaluator does not share a store with whatever built it -- never have been
//! here at all.
//!
//! So the path is checked, fetched from `eval_substituter` if one is
//! configured, and checked again. An input whose build is unavailable
//! contributes nothing, which is what it did before this was Rust.
//!
//! Both are asked of the `nix` command rather than the daemon: the command
//! talks to whatever store `NIX_REMOTE` names, daemon or not, so this works
//! wherever `nix copy` does.

use db::StoreDir;

/// Whether a build's output can be given to an evaluation.
#[derive(Debug)]
pub(crate) struct Availability {
    store_dir: StoreDir,
    substituter: Option<String>,
}

impl Availability {
    pub(crate) fn new(store_dir: StoreDir, substituter: Option<String>) -> Self {
        Self {
            store_dir,
            substituter,
        }
    }

    pub(crate) fn store_dir(&self) -> &StoreDir {
        &self.store_dir
    }

    /// Whether `path` is in the store, fetching it first if it is not and a
    /// substituter is configured.
    ///
    /// A fetch that fails is "not available": this decides whether an input
    /// has something to contribute, and a failed fetch does not mean it does.
    /// Logged rather than raised, because a jobset with one stale `build`
    /// input should still evaluate.
    pub(crate) async fn is_available(&self, path: &str) -> bool {
        // Full paths as `nix` wants them; the database keeps them full, the
        // fetcher reports bare names. Anything malformed fails the check.
        let full = if path.starts_with('/') {
            path.to_owned()
        } else {
            format!("{}/{path}", self.store_dir.to_path().display())
        };

        if is_valid(&full).await {
            return true;
        }
        let Some(substituter) = &self.substituter else {
            return false;
        };

        tracing::info!("fetching `{full}' from {substituter}");
        let fetched = tokio::process::Command::new("nix")
            .args([
                "--extra-experimental-features",
                "nix-command",
                "copy",
                "--from",
            ])
            .arg(substituter)
            .arg("--")
            .arg(&full)
            .status()
            .await;
        match fetched {
            Ok(status) if status.success() => {}
            Ok(status) => tracing::warn!("could not fetch `{full}' from {substituter}: {status}"),
            Err(e) => tracing::warn!("could not run nix copy: {e}"),
        }

        is_valid(&full).await
    }
}

async fn is_valid(full: &str) -> bool {
    tokio::process::Command::new("nix-store")
        .args(["--check-validity", "--", full])
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}
