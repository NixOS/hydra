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
//! contributes nothing.
//!
//! Validity is asked of the nix-daemon, as the queue runner asks it. Fetching
//! is `nix copy`, which the daemon protocol has no equivalent for.

use daemon_client_utils::DaemonStoreReader;
use db::StoreDir;
use harmonia_store_path::StorePath;

/// Whether a build's output can be given to an evaluation.
#[derive(Debug)]
pub(crate) struct Availability {
    store: DaemonStoreReader,
    substituter: Option<String>,
}

impl Availability {
    pub(crate) fn new(store: DaemonStoreReader, substituter: Option<String>) -> Self {
        Self { store, substituter }
    }

    pub(crate) fn store_dir(&self) -> &StoreDir {
        self.store.store_dir()
    }

    /// Whether `path` is in the store, fetching it first if it is not and a
    /// substituter is configured.
    ///
    /// A fetch that fails is "not available": this decides whether an input
    /// has something to contribute, and a failed fetch does not mean it does.
    /// Logged rather than raised, because a jobset with one stale `build`
    /// input should still evaluate.
    pub(crate) async fn is_available(&self, path: &str) -> bool {
        let full = crate::nix_eval_jobs::full(self.store_dir(), path);
        if self.check(&full).await {
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
            .kill_on_drop(true)
            .output()
            .await;
        match fetched {
            Ok(out) if out.status.success() => {}
            Ok(out) => {
                tracing::warn!(
                    "could not fetch `{full}' from {substituter}: {}",
                    out.status
                );
                tracing::debug!(
                    "nix copy: {}",
                    std::str::from_utf8(&out.stderr)
                        .unwrap_or("<non-UTF-8>")
                        .trim_end()
                );
            }
            Err(e) => tracing::warn!("could not run nix copy: {e}"),
        }

        self.check(&full).await
    }

    /// Whether `path` is in the store already, without fetching it.
    pub(crate) async fn is_valid(&self, path: &str) -> bool {
        self.check(&crate::nix_eval_jobs::full(self.store_dir(), path))
            .await
    }

    /// Whether the full store path `full` is valid. A path that does not
    /// parse, or a daemon that cannot answer, counts as no.
    async fn check(&self, full: &str) -> bool {
        let Ok(store_path) = self.store_dir().parse::<StorePath>(full) else {
            return false;
        };
        match self.store.is_valid_path(&store_path).await {
            Ok(valid) => valid,
            Err(e) => {
                tracing::warn!("could not ask the nix-daemon whether `{full}' is valid: {e}");
                false
            }
        }
    }
}
