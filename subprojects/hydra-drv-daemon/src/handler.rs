use std::future::{Future, ready};
use std::pin::Pin;

use tokio::io::AsyncBufRead;

use harmonia_protocol::daemon::{
    DaemonError as ProtocolError, DaemonResult, DaemonStore, FutureResultExt, HandshakeDaemonStore,
    ResultLog, ResultLogExt, TrustLevel,
};
use harmonia_protocol::types::AddToStoreItem;
use harmonia_protocol::valid_path_info::{UnkeyedValidPathInfo, ValidPathInfo};
use harmonia_store_core::store_path::{
    ContentAddressMethodAlgorithm, StorePath, StorePathHash, StorePathSet,
};
use harmonia_store_remote::pool::{ConnectionPool, PoolConfig};

use db::StoreDir;

/// Nix daemon handler that intercepts derivation writes and decomposes
/// them into the drv-in-db Postgres tables, proxying read operations
/// to the host nix daemon.
#[derive(Clone)]
pub struct DrvDaemonHandler {
    store_dir: StoreDir,
    db: db::Database,
    upstream: ConnectionPool,
}

impl std::fmt::Debug for DrvDaemonHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DrvDaemonHandler")
            .field("store_dir", &self.store_dir)
            .finish_non_exhaustive()
    }
}

impl DrvDaemonHandler {
    pub fn new(store_dir: StoreDir, db: db::Database, upstream_socket: &str) -> Self {
        let upstream = ConnectionPool::new(upstream_socket, PoolConfig::default());
        Self {
            store_dir,
            db,
            upstream,
        }
    }

    /// Read a .drv file from the store, parse it, and insert into the
    /// drv-in-db tables (Derivations + 5 child tables).
    async fn intercept_derivation(&self, path: &StorePath) -> Result<(), ProtocolError> {
        let full_path = format!("{}/{}", self.store_dir, path);

        let content = match tokio::fs::read_to_string(&full_path).await {
            Ok(c) => c,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::warn!(
                    path = %full_path,
                    "drv file not on disk (upstream may have drv-in-db enabled), skipping"
                );
                return Ok(());
            }
            Err(e) => return Err(ProtocolError::custom(format!("read {full_path}: {e}"))),
        };

        let drv = harmonia_store_aterm::parse_derivation_aterm(
            &self.store_dir,
            &content,
            path.name().clone(),
        )
        .map_err(|e| ProtocolError::custom(format!("parse {full_path}: {e}")))?;

        let mut conn = self
            .db
            .get()
            .await
            .map_err(|e| ProtocolError::custom(format!("hydra db: {e}")))?;

        match conn
            .insert_derivation(&full_path, &drv, &self.store_dir)
            .await
        {
            Ok(Some(id)) => {
                tracing::info!(
                    path = %full_path,
                    drv_id = id,
                    outputs = ?drv.outputs.keys().collect::<Vec<_>>(),
                    "inserted derivation"
                );
            }
            Ok(None) => {
                tracing::debug!(path = %full_path, "derivation already exists, skipped");
            }
            Err(e) => return Err(ProtocolError::custom(format!("insert drv: {e}"))),
        }

        Ok(())
    }
}

impl HandshakeDaemonStore for DrvDaemonHandler {
    type Store = Self;

    fn handshake(self) -> impl ResultLog<Output = DaemonResult<Self::Store>> + Send {
        ready(Ok(self)).empty_logs()
    }
}

impl DaemonStore for DrvDaemonHandler {
    fn trust_level(&self) -> TrustLevel {
        TrustLevel::Trusted
    }

    fn set_options<'a>(
        &'a mut self,
        _options: &'a harmonia_protocol::types::ClientOptions,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        ready(Ok(())).empty_logs()
    }

    fn is_valid_path<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<bool>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.client().is_valid_path(path).await
        }
        .empty_logs()
    }

    fn query_valid_paths<'a>(
        &'a mut self,
        paths: &'a StorePathSet,
        substitute: bool,
    ) -> impl ResultLog<Output = DaemonResult<StorePathSet>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.client().query_valid_paths(paths, substitute).await
        }
        .empty_logs()
    }

    fn query_path_info<'a>(
        &'a mut self,
        path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<Option<UnkeyedValidPathInfo>>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.client().query_path_info(path).await
        }
        .empty_logs()
    }

    fn query_path_from_hash_part<'a>(
        &'a mut self,
        hash: &'a StorePathHash,
    ) -> impl ResultLog<Output = DaemonResult<Option<StorePath>>> + Send + 'a {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard.client().query_path_from_hash_part(hash).await
        }
        .empty_logs()
    }

    fn add_temp_root<'a>(
        &'a mut self,
        _path: &'a StorePath,
    ) -> impl ResultLog<Output = DaemonResult<()>> + Send + 'a {
        ready(Ok(())).empty_logs()
    }

    fn add_ca_to_store<'a, 'r, R>(
        &'a mut self,
        name: &'a str,
        cam: ContentAddressMethodAlgorithm,
        refs: &'a StorePathSet,
        repair: bool,
        source: R,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<ValidPathInfo>> + Send + 'r>>
    where
        R: AsyncBufRead + Send + Unpin + 'r,
        'a: 'r,
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .client()
                .add_ca_to_store(name, cam, refs, repair, source)
                .await
        }
        .empty_logs()
        .boxed_result()
    }

    fn add_multiple_to_store<'s, 'i, 'r, S, R>(
        &'s mut self,
        repair: bool,
        dont_check_sigs: bool,
        stream: S,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<()>> + Send + 'r>>
    where
        S: futures::Stream<Item = Result<AddToStoreItem<R>, ProtocolError>> + Send + 'i,
        R: AsyncBufRead + Send + Unpin + 'i,
        's: 'r,
        'i: 'r,
    {
        let upstream = self.upstream.clone();
        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .client()
                .add_multiple_to_store(repair, dont_check_sigs, stream)
                .await
        }
        .empty_logs()
        .boxed_result()
    }

    fn add_to_store_nar<'s, 'r, 'i, R>(
        &'s mut self,
        info: &'i ValidPathInfo,
        source: R,
        repair: bool,
        dont_check_sigs: bool,
    ) -> Pin<Box<dyn ResultLog<Output = DaemonResult<()>> + Send + 'r>>
    where
        R: AsyncBufRead + Send + Unpin + 'r,
        's: 'r,
        'i: 'r,
    {
        let is_drv = info.path.name().as_ref().ends_with(".drv");
        let drv_path = info.path.clone();
        let this = self.clone();
        let upstream = self.upstream.clone();

        async move {
            let mut guard = upstream
                .acquire()
                .await
                .map_err(|e| ProtocolError::custom(format!("upstream pool: {e}")))?;
            guard
                .client()
                .add_to_store_nar(info, source, repair, dont_check_sigs)
                .await?;
            drop(guard);

            if is_drv {
                this.intercept_derivation(&drv_path).await?;
            }

            Ok(())
        }
        .empty_logs()
        .boxed_result()
    }

    fn shutdown(&mut self) -> impl Future<Output = DaemonResult<()>> + Send + '_ {
        ready(Ok(()))
    }
}
