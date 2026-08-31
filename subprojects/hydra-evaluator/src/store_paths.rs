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

use daemon_client_utils::DaemonStoreReader;
use db::StoreDir;

/// Whether a build's output can be given to an evaluation.
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
    /// A path that cannot be parsed, a daemon that cannot be reached and a
    /// fetch that fails are all "not available": this decides whether an input
    /// has something to contribute, and none of them mean it does. They are
    /// logged rather than raised, because a jobset with one stale `build`
    /// input should still evaluate.
    pub(crate) async fn is_available(&self, path: &str) -> bool {
        let Ok(parsed) = self.store_dir().parse(path) else {
            tracing::warn!("cannot read `{path}' as a store path");
            return false;
        };

        match self.store.is_valid_path(&parsed).await {
            Ok(true) => return true,
            Ok(false) => {}
            Err(e) => {
                tracing::warn!("could not ask the daemon about `{path}': {e}");
                return false;
            }
        }

        let Some(substituter) = &self.substituter else {
            return false;
        };

        // `nix copy` wants the path as it appears on disk, not as the bare
        // name the database keeps.
        let full = self.store_dir().display(&parsed);
        tracing::info!("fetching `{full}' from {substituter}");

        let fetched = tokio::process::Command::new("nix")
            .args([
                "--experimental-features",
                "nix-command",
                "copy",
                "--from",
                substituter,
                "--",
            ])
            .arg(full.to_string())
            .status()
            .await;

        match fetched {
            Ok(status) if status.success() => {}
            Ok(status) => {
                tracing::warn!("could not fetch `{full}' from {substituter}: {status}");
            }
            Err(e) => tracing::warn!("could not run nix copy: {e}"),
        }

        self.store.is_valid_path(&parsed).await.unwrap_or(false)
    }
}
