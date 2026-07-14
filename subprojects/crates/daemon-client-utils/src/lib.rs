//! Utilities for working with the Nix daemon beyond what the
//! harmonia libraries provide.

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use harmonia_protocol::types::{DaemonError, DaemonStore};
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::ValidPathInfo;
use harmonia_store_remote::{DaemonClient, DaemonClientBuilder};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

/// A live, handshaked connection to the Nix daemon over a unix socket.
pub type DaemonConn = DaemonClient<OwnedReadHalf, OwnedWriteHalf>;

/// Opens a fresh daemon connection per operation; intentionally not pooled.
///
/// The remaining daemon operations are all long-lived streaming ones (build,
/// import, export, substitute), so the handshake cost is negligible. A pooled
/// connection abandoned mid-stream (e.g. a cancelled gRPC transfer) stays
/// desynced and corrupts whoever gets it next; a fresh connection just closes
/// its socket on drop and cannot poison anything.
#[derive(Clone)]
pub struct DaemonConnector {
    socket: PathBuf,
    store_dir: StoreDir,
}

impl DaemonConnector {
    pub fn new(socket: impl Into<PathBuf>, store_dir: StoreDir) -> Self {
        Self {
            socket: socket.into(),
            store_dir,
        }
    }

    pub fn store_dir(&self) -> &StoreDir {
        &self.store_dir
    }

    /// Open and handshake a new daemon connection.
    pub async fn connect(&self) -> Result<DaemonConn, DaemonError> {
        DaemonClientBuilder::new()
            .set_store_dir(&self.store_dir)
            .connect_unix(&self.socket)
            .await
    }
}

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
    /// Chroot root directory, if any (e.g. `/foo`). A physical path.
    pub root: Option<PathBuf>,
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
            self.root.as_ref().map(|root| root.join("nix/store"))
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
            params.push(format!("root={}", root.display()));
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
                "root" => root = Some(PathBuf::from(v.as_ref())),
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
        r.join(DEFAULT_STATE_DIR_RELATIVE)
    } else if let Some(s) = explicit_state_dir {
        PathBuf::from(s)
    } else {
        PathBuf::from("/").join(DEFAULT_STATE_DIR_RELATIVE)
    };

    // Derive socket. URI path overrides everything; NIX_DAEMON_SOCKET_PATH
    // is a fallback for when the URI has no path (e.g. `unix://?store=...`).
    // Final default: stateDir / "daemon-socket/socket".
    let socket = match socket_from_uri.or(explicit_socket) {
        Some(s) => s,
        None => state_dir
            .join("daemon-socket/socket")
            .into_os_string()
            .into_string()
            .map_err(|p| format!("derived socket path is not valid UTF-8: {p:?}"))?,
    };

    Ok(NixDaemonStoreConfig {
        socket,
        store_dir: StoreDir::new(store).map_err(|e| e.to_string())?,
        root,
        real,
        state_dir,
    })
}

/// Ensure a path is present in the store (via substitution).
pub async fn ensure_path(conn: &mut DaemonConn, path: &StorePath) -> Result<(), DaemonError> {
    conn.ensure_path(path).await
}

/// Reads store metadata through the nix-daemon. Needs no access to the store
/// database files and reflects registrations still in its uncheckpointed WAL.
#[derive(Clone)]
pub struct DaemonStoreReader {
    connector: DaemonConnector,
}

impl DaemonStoreReader {
    pub fn new(connector: DaemonConnector) -> Self {
        Self { connector }
    }

    pub fn store_dir(&self) -> &StoreDir {
        self.connector.store_dir()
    }

    /// Open a connection callers can reuse across several queries to avoid a
    /// handshake per query (see the free `query_*` functions below).
    pub async fn connect(&self) -> Result<DaemonConn, DaemonError> {
        self.connector.connect().await
    }

    pub async fn is_valid_path(&self, path: &StorePath) -> Result<bool, DaemonError> {
        self.connect().await?.is_valid_path(path).await
    }

    pub async fn query_path_info(
        &self,
        path: &StorePath,
    ) -> Result<Option<ValidPathInfo>, DaemonError> {
        query_path_info(&mut self.connect().await?, path).await
    }

    pub async fn query_closure_infos(
        &self,
        roots: Vec<StorePath>,
    ) -> Result<Vec<ValidPathInfo>, DaemonError> {
        query_closure_infos(&mut self.connect().await?, roots).await
    }

    pub async fn compute_closure_size(&self, path: &StorePath) -> u64 {
        let Ok(mut conn) = self.connect().await else {
            return 0;
        };
        compute_closure_size(&mut conn, path).await
    }
}

/// A bounded, reusable set of daemon connections for a burst of read-only
/// queries. It caps live connections at `max` and hands them back for reuse,
/// so a fan-out of validity checks costs at most `max` handshakes rather than
/// one per query. Drop the pool when the burst ends to close the connections;
/// nothing stays open between bursts.
pub struct DaemonConnPool {
    reader: DaemonStoreReader,
    idle: Mutex<Vec<DaemonConn>>,
    sem: Arc<tokio::sync::Semaphore>,
}

impl DaemonConnPool {
    pub fn new(reader: DaemonStoreReader, max: usize) -> Arc<Self> {
        Arc::new(Self {
            reader,
            idle: Mutex::new(Vec::new()),
            sem: Arc::new(tokio::sync::Semaphore::new(max)),
        })
    }

    /// Lease a connection, reusing an idle one or opening a new one up to the
    /// pool's cap. Blocks once `max` connections are in use.
    pub async fn acquire(self: &Arc<Self>) -> Result<PooledConn, DaemonError> {
        let permit = self
            .sem
            .clone()
            .acquire_owned()
            .await
            .expect("daemon pool semaphore is never closed");
        let reused = self.idle.lock().unwrap().pop();
        let conn = match reused {
            Some(conn) => conn,
            None => self.reader.connect().await?,
        };
        Ok(PooledConn {
            conn: Some(conn),
            broken: false,
            pool: self.clone(),
            _permit: permit,
        })
    }
}

/// A connection leased from a [`DaemonConnPool`], returned to the pool on drop
/// unless it was marked broken by a failed query.
pub struct PooledConn {
    conn: Option<DaemonConn>,
    broken: bool,
    pool: Arc<DaemonConnPool>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}

impl PooledConn {
    /// Check path validity. A daemon error can leave the connection desynced,
    /// so on error it is dropped instead of returned to the pool.
    pub async fn is_valid_path(&mut self, path: &StorePath) -> Result<bool, DaemonError> {
        let conn = self.conn.as_mut().expect("leased connection already taken");
        match conn.is_valid_path(path).await {
            Ok(valid) => Ok(valid),
            Err(e) => {
                self.broken = true;
                Err(e)
            }
        }
    }
}

impl Drop for PooledConn {
    fn drop(&mut self) {
        if let Some(conn) = self.conn.take()
            && !self.broken
        {
            self.pool.idle.lock().unwrap().push(conn);
        }
    }
}

pub async fn query_path_info(
    conn: &mut DaemonConn,
    path: &StorePath,
) -> Result<Option<ValidPathInfo>, DaemonError> {
    Ok(conn.query_path_info(path).await?.map(|info| ValidPathInfo {
        path: path.clone(),
        info,
    }))
}

/// Closure of `roots` with full path info, dependencies before dependents.
/// Invalid roots are skipped.
pub async fn query_closure_infos(
    conn: &mut DaemonConn,
    roots: Vec<StorePath>,
) -> Result<Vec<ValidPathInfo>, DaemonError> {
    enum Frame {
        Enter(StorePath),
        Exit(StorePath),
    }
    let mut seen: BTreeSet<StorePath> = BTreeSet::new();
    let mut pending: HashMap<StorePath, _> = HashMap::new();
    let mut sorted = Vec::new();
    // Iterative post-order DFS: dependencies emitted before dependents.
    let mut stack: Vec<Frame> = roots.into_iter().map(Frame::Enter).collect();
    while let Some(frame) = stack.pop() {
        match frame {
            Frame::Enter(p) => {
                if !seen.insert(p.clone()) {
                    continue;
                }
                let Some(info) = conn.query_path_info(&p).await? else {
                    continue;
                };
                stack.push(Frame::Exit(p.clone()));
                for r in &info.references {
                    if *r != p && !seen.contains(r) {
                        stack.push(Frame::Enter(r.clone()));
                    }
                }
                pending.insert(p, info);
            }
            Frame::Exit(p) => {
                if let Some(info) = pending.remove(&p) {
                    sorted.push(ValidPathInfo { path: p, info });
                }
            }
        }
    }
    Ok(sorted)
}

pub async fn compute_closure_size(conn: &mut DaemonConn, path: &StorePath) -> u64 {
    query_closure_infos(conn, vec![path.clone()])
        .await
        .map(|infos| infos.iter().map(|i| i.info.nar_size).sum())
        .unwrap_or(0)
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
