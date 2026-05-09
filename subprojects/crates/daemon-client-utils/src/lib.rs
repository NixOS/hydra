//! Utilities for working with the Nix daemon beyond what the
//! harmonia libraries provide.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use harmonia_protocol::types::{DaemonError, DaemonStore};
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::ValidPathInfo;
use harmonia_store_remote::ConnectionPool;

/// Parsed nix daemon store connection settings.
///
/// Constructed by [`parse_nix_remote`] from `NIX_REMOTE` and fallback
/// env vars. Precedence rules match nix's `LocalFSStoreConfig`:
/// URI query params (`?store=`, `?root=`, `?state=`, `?real=`)
/// override env vars; `?root=` derives default state and real store
/// dirs.
///
/// Use [`to_uri`](Self::to_uri) to reconstruct a `unix://` URI
/// suitable for `nix copy --from` etc.
pub struct NixDaemonStoreConfig {
    /// Path to the daemon socket.
    pub socket: String,
    /// Logical store directory (e.g. `/nix/store`).
    pub store_dir: StoreDir,
    /// Chroot root directory, if any (e.g. `/foo`).
    pub root: Option<String>,
    /// Explicit physical store directory override (`real` query param).
    real: Option<PathBuf>,
    /// Nix state directory (e.g. `/nix/var/nix`).
    pub state_dir: PathBuf,
}

impl NixDaemonStoreConfig {
    /// Physical store directory on disk, if it differs from the
    /// logical store dir.
    ///
    /// Matches nix's `LocalFSStoreConfig::realStoreDir`:
    /// - `?real=` if explicitly set
    /// - `root / "nix/store"` if `?root=` is set (hardcoded, not derived from `store`)
    /// - `None` otherwise (callers should use `store_dir`)
    pub fn real_store_dir(&self) -> Option<PathBuf> {
        if let Some(ref real) = self.real {
            Some(real.clone())
        } else {
            self.root
                .as_ref()
                .map(|root| PathBuf::from(root).join("nix/store"))
        }
    }

    /// Reconstruct a `unix://` URI suitable for `nix copy --from` etc.
    pub fn to_uri(&self) -> String {
        let mut uri = format!("unix://{}", self.socket);
        let mut params = Vec::new();
        let store_str = self.store_dir.to_string();
        if store_str != "/nix/store" {
            params.push(format!("store={store_str}"));
        }
        if let Some(ref root) = self.root {
            params.push(format!("root={root}"));
        }
        if let Some(ref real) = self.real {
            params.push(format!("real={}", real.display()));
        }
        if !params.is_empty() {
            uri.push('?');
            uri.push_str(&params.join("&"));
        }
        uri
    }
}

/// Default nix state directory relative path (under root).
const DEFAULT_STATE_DIR_RELATIVE: &str = "nix/var/nix";

/// Parse daemon store settings from `NIX_REMOTE` and related env vars.
pub fn parse_nix_remote() -> Result<NixDaemonStoreConfig, String> {
    parse_nix_remote_from(
        std::env::var("NIX_REMOTE").ok().as_deref(),
        std::env::var("NIX_STORE_DIR").ok().as_deref(),
        std::env::var("NIX_STATE_DIR").ok().as_deref(),
        std::env::var("NIX_DAEMON_SOCKET_PATH").ok().as_deref(),
    )
}

/// Factored out pure internal function for unit testing purposes.
fn parse_nix_remote_from(
    nix_remote: Option<&str>,
    nix_store_dir: Option<&str>,
    nix_state_dir: Option<&str>,
    nix_daemon_socket_path: Option<&str>,
) -> Result<NixDaemonStoreConfig, String> {
    let explicit_state_dir = nix_state_dir.map(String::from);
    let explicit_socket = nix_daemon_socket_path.map(String::from);
    let mut socket_from_uri = None;
    let mut state_from_uri = None;
    let mut store = nix_store_dir
        .map(String::from)
        .unwrap_or_else(|| "/nix/store".to_owned());
    let mut root = None;
    let mut real = None;

    // NIX_REMOTE URL query params override env vars.
    if let Some(remote) = nix_remote
        && remote.starts_with("unix://")
    {
        let parsed = url::Url::parse(remote).map_err(|e| e.to_string())?;
        let path = parsed.path();
        if !path.is_empty() {
            socket_from_uri = Some(path.to_owned());
        }

        for (k, v) in parsed.query_pairs() {
            match k.as_ref() {
                "store" => store = v.into_owned(),
                "root" => root = Some(v.into_owned()),
                "real" => real = Some(PathBuf::from(v.as_ref())),
                "state" => state_from_uri = Some(PathBuf::from(v.as_ref())),
                _ => {}
            }
        }
    }

    // Derive state_dir matching nix's LocalFSStoreConfig::stateDir:
    //   ?state= > (root / "nix/var/nix" if root set, else NIX_STATE_DIR)
    let state_dir = if let Some(s) = state_from_uri {
        s
    } else if let Some(ref r) = root {
        PathBuf::from(r).join(DEFAULT_STATE_DIR_RELATIVE)
    } else if let Some(s) = explicit_state_dir {
        PathBuf::from(s)
    } else {
        PathBuf::from("/").join(DEFAULT_STATE_DIR_RELATIVE)
    };

    // Derive socket. URI path overrides everything; NIX_DAEMON_SOCKET_PATH
    // is a fallback for when the URI has no path (e.g. `unix://?store=...`).
    // Final default: stateDir / "daemon-socket/socket".
    let socket = socket_from_uri.or(explicit_socket).unwrap_or_else(|| {
        state_dir
            .join("daemon-socket/socket")
            .to_string_lossy()
            .into_owned()
    });

    Ok(NixDaemonStoreConfig {
        socket,
        store_dir: StoreDir::new(store).map_err(|e| e.to_string())?,
        root,
        real,
        state_dir,
    })
}

/// Walk store path references transitively, collecting all path infos
/// in the closure. No particular ordering is guaranteed.
async fn walk_closure(
    pool: &ConnectionPool,
    roots: &[StorePath],
) -> Result<HashMap<StorePath, harmonia_store_path_info::UnkeyedValidPathInfo>, DaemonError> {
    let mut infos = HashMap::new();
    let mut queue: Vec<StorePath> = roots.to_vec();
    let mut visited = HashSet::new();
    while let Some(p) = queue.pop() {
        if !visited.insert(p.clone()) {
            continue;
        }
        let mut guard = pool.acquire().await?;
        let info = guard
            .client()
            .query_path_info(&p)
            .await?
            .ok_or_else(|| DaemonError::custom(format!("path '{p}' is not valid")))?;
        for r in &info.references {
            if !visited.contains(r) {
                queue.push(r.clone());
            }
        }
        infos.insert(p, info);
    }
    Ok(infos)
}

/// Walk store path references transitively to compute the closure.
///
/// Returns `ValidPathInfo`s topologically sorted (dependencies before
/// dependents) via `petgraph`. This ordering is required by
/// `add_to_store_nar`, which validates that all references already
/// exist before accepting a path.
pub async fn query_closure(
    pool: &ConnectionPool,
    roots: &[StorePath],
) -> Result<Vec<ValidPathInfo>, DaemonError> {
    use petgraph::graphmap::DiGraphMap;

    let mut infos = walk_closure(pool, roots).await?;

    // Topological sort so dependencies come before dependents.
    let sorted_paths = {
        let mut graph = DiGraphMap::<&StorePath, ()>::new();
        for p in infos.keys() {
            graph.add_node(p);
        }
        for (p, info) in &infos {
            for r in &info.references {
                if r != p && infos.contains_key(r) {
                    graph.add_edge(p, r, ());
                }
            }
        }
        // petgraph toposort returns dependents before dependencies,
        // so reverse to get dependencies first.
        let sorted = petgraph::algo::toposort(&graph, None)
            .expect("store reference graph should be acyclic");
        sorted
            .into_iter()
            .rev()
            .cloned()
            .collect::<Vec<StorePath>>()
    };

    Ok(sorted_paths
        .into_iter()
        .filter_map(|p| {
            let info = infos.remove(&p)?;
            Some(ValidPathInfo { path: p, info })
        })
        .collect())
}

/// Compute the total NAR size of a path's closure.
pub async fn compute_closure_size(pool: &ConnectionPool, path: &StorePath) -> u64 {
    walk_closure(pool, &[path.clone()])
        .await
        .map(|infos| infos.values().map(|info| info.nar_size).sum())
        .unwrap_or(0)
}

/// Check whether a store path is valid.
pub async fn is_valid_path(pool: &ConnectionPool, path: &StorePath) -> Result<bool, DaemonError> {
    let mut guard = pool.acquire().await?;
    guard.client().is_valid_path(path).await
}

/// Query path info, returning `None` if the path is not valid.
pub async fn query_path_info(
    pool: &ConnectionPool,
    path: &StorePath,
) -> Result<Option<harmonia_store_path_info::UnkeyedValidPathInfo>, DaemonError> {
    let mut guard = pool.acquire().await?;
    guard.client().query_path_info(path).await
}

/// Ensure a path is present in the store (via substitution).
pub async fn ensure_path(pool: &ConnectionPool, path: &StorePath) -> Result<(), DaemonError> {
    let mut guard = pool.acquire().await?;
    guard.client().ensure_path(path).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(
        remote: Option<&str>,
        store_dir: Option<&str>,
        state_dir: Option<&str>,
        socket_path: Option<&str>,
    ) -> NixDaemonStoreConfig {
        parse_nix_remote_from(remote, store_dir, state_dir, socket_path).unwrap()
    }

    #[test]
    fn defaults() {
        let c = parse(None, None, None, None);
        assert_eq!(c.socket, "/nix/var/nix/daemon-socket/socket");
        assert_eq!(c.store_dir.to_string(), "/nix/store");
        assert_eq!(c.state_dir, PathBuf::from("/nix/var/nix"));
        assert_eq!(c.real_store_dir(), None);
        assert_eq!(c.root, None);
    }

    #[test]
    fn env_overrides() {
        let c = parse(
            None,
            Some("/custom/store"),
            Some("/custom/state"),
            Some("/custom/socket"),
        );
        assert_eq!(c.socket, "/custom/socket");
        assert_eq!(c.store_dir.to_string(), "/custom/store");
        assert_eq!(c.state_dir, PathBuf::from("/custom/state"));
        assert_eq!(c.real_store_dir(), None);
    }

    #[test]
    fn unix_uri_socket_path() {
        let c = parse(Some("unix:///run/nix/socket"), None, None, None);
        assert_eq!(c.socket, "/run/nix/socket");
        // URI path overrides NIX_DAEMON_SOCKET_PATH
        let c = parse(
            Some("unix:///run/nix/socket"),
            None,
            None,
            Some("/other/socket"),
        );
        assert_eq!(c.socket, "/run/nix/socket");
    }

    #[test]
    fn unix_uri_empty_path_falls_back_to_env() {
        let c = parse(Some("unix://?store=/foo"), None, None, Some("/env/socket"));
        assert_eq!(c.socket, "/env/socket");
    }

    #[test]
    fn root_derives_state_and_real_store() {
        let c = parse(Some("unix:///sock?root=/chroot"), None, None, None);
        assert_eq!(c.state_dir, PathBuf::from("/chroot/nix/var/nix"));
        assert_eq!(c.real_store_dir(), Some(PathBuf::from("/chroot/nix/store")));
        assert_eq!(c.store_dir.to_string(), "/nix/store");
    }

    #[test]
    fn root_overrides_nix_state_dir() {
        // root takes precedence over NIX_STATE_DIR for state_dir
        let c = parse(
            Some("unix:///sock?root=/chroot"),
            None,
            Some("/env/state"),
            None,
        );
        assert_eq!(c.state_dir, PathBuf::from("/chroot/nix/var/nix"));
    }

    #[test]
    fn explicit_state_param_overrides_root() {
        let c = parse(
            Some("unix:///sock?root=/chroot&state=/explicit/state"),
            None,
            None,
            None,
        );
        assert_eq!(c.state_dir, PathBuf::from("/explicit/state"));
    }

    #[test]
    fn explicit_real_overrides_root_derived() {
        let c = parse(
            Some("unix:///sock?root=/chroot&real=/explicit/real"),
            None,
            None,
            None,
        );
        assert_eq!(c.real_store_dir(), Some(PathBuf::from("/explicit/real")));
    }

    #[test]
    fn root_with_custom_store_still_uses_nix_store_for_real() {
        // Even with a custom logical store, realStoreDir is root/"nix/store"
        // (matching nix's hardcoded default)
        let c = parse(
            Some("unix:///sock?root=/chroot&store=/custom/store"),
            None,
            None,
            None,
        );
        assert_eq!(c.store_dir.to_string(), "/custom/store");
        assert_eq!(c.real_store_dir(), Some(PathBuf::from("/chroot/nix/store")));
    }

    #[test]
    fn socket_derived_from_state_dir() {
        // No URI, no NIX_DAEMON_SOCKET_PATH — socket comes from state_dir
        let c = parse(None, None, Some("/custom/state"), None);
        assert_eq!(c.socket, "/custom/state/daemon-socket/socket");
    }

    #[test]
    fn socket_derived_from_root_state_dir() {
        // root derives state_dir, which derives socket
        let c = parse(Some("unix://?root=/chroot"), None, None, None);
        assert_eq!(c.socket, "/chroot/nix/var/nix/daemon-socket/socket");
    }

    #[test]
    fn to_uri_roundtrip_default() {
        let c = parse(None, None, None, None);
        assert_eq!(c.to_uri(), "unix:///nix/var/nix/daemon-socket/socket");
    }

    #[test]
    fn to_uri_with_root_and_store() {
        let c = parse(
            Some("unix:///sock?root=/chroot&store=/custom/store"),
            None,
            None,
            None,
        );
        let uri = c.to_uri();
        assert!(uri.contains("store=/custom/store"));
        assert!(uri.contains("root=/chroot"));
    }
}
