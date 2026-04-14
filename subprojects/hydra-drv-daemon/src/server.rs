// Nix daemon server, using harmonia-protocol's wire types.
// Derived from harmonia-daemon::server (EUPL-1.2 OR MIT).

use std::fmt::Debug;
use std::path::PathBuf;
use std::pin::pin;

use futures::{FutureExt, StreamExt as _};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, copy_buf};
use tokio::net::UnixListener;
use tracing::{debug, error, info};

use harmonia_protocol::ProtocolVersion;
use harmonia_protocol::daemon::{
    DaemonError, DaemonResult, DaemonStore, HandshakeDaemonStore, ResultLog,
    wire::{
        CLIENT_MAGIC, FramedReader, IgnoredOne, SERVER_MAGIC,
        logger::RawLogMessage,
        parse_add_multiple_to_store,
        types2::{BaseStorePath, Request},
    },
};
use harmonia_protocol::de::{NixRead, NixReader};
use harmonia_protocol::log::LogMessage;
use harmonia_protocol::ser::{NixWrite, NixWriter};
use harmonia_store_core::store_path::StoreDir;
use harmonia_utils_io::{AsyncBufReadCompat, BytesReader};

const PROTOCOL_VERSION: ProtocolVersion = ProtocolVersion::from_parts(1, 37);
const NIX_VERSION: &str = "2.24.0 (Hydra)";

struct RecoverableError {
    can_recover: bool,
    source: DaemonError,
}

impl<T: Into<DaemonError>> From<T> for RecoverableError {
    fn from(source: T) -> Self {
        RecoverableError {
            can_recover: false,
            source: source.into(),
        }
    }
}

trait RecoverExt<T> {
    fn recover(self) -> Result<T, RecoverableError>;
}

impl<T, E: Into<DaemonError>> RecoverExt<T> for Result<T, E> {
    fn recover(self) -> Result<T, RecoverableError> {
        self.map_err(|source| RecoverableError {
            can_recover: true,
            source: source.into(),
        })
    }
}

fn log_to_raw(msg: LogMessage) -> RawLogMessage {
    match msg {
        LogMessage::Message(m) => RawLogMessage::Next(m.text),
        LogMessage::StartActivity(a) => RawLogMessage::StartActivity(a),
        LogMessage::StopActivity(a) => RawLogMessage::StopActivity(a),
        LogMessage::Result(r) => RawLogMessage::Result(r),
    }
}

async fn write_log<W>(writer: &mut NixWriter<W>, msg: LogMessage) -> Result<(), RecoverableError>
where
    W: AsyncWrite + Send + Unpin,
{
    writer.write_value(&log_to_raw(msg)).await?;
    Ok(())
}

async fn process_logs<'s, T: Send + 's, W>(
    writer: &mut NixWriter<W>,
    logs: impl ResultLog<Output = DaemonResult<T>> + Send + 's,
) -> Result<T, RecoverableError>
where
    W: AsyncWrite + Send + Unpin,
{
    let mut logs = pin!(logs);
    while let Some(msg) = logs.next().await {
        write_log(writer, msg).await?;
    }
    logs.await.recover()
}

struct DaemonConnection<R, W> {
    reader: NixReader<BytesReader<R>>,
    writer: NixWriter<W>,
}

impl<R, W> DaemonConnection<R, W>
where
    R: AsyncRead + Debug + Send + Unpin,
    W: AsyncWrite + Debug + Send + Unpin,
{
    async fn handshake(&mut self) -> DaemonResult<()> {
        let magic: u64 = self.reader.read_number().await?;
        if magic != CLIENT_MAGIC {
            return Err(DaemonError::custom(format!("bad client magic: {magic:#x}")));
        }
        self.writer.write_number(SERVER_MAGIC).await?;
        self.writer.write_value(&PROTOCOL_VERSION).await?;
        self.writer.flush().await?;

        let client_version: ProtocolVersion = self.reader.read_value().await?;
        self.reader.set_version(client_version);
        self.writer.set_version(client_version);

        if client_version.minor() >= 14 {
            let _: bool = self.reader.read_value().await?;
        }
        if client_version.minor() >= 11 {
            let _: bool = self.reader.read_value().await?;
        }
        if client_version.minor() >= 33 {
            self.writer.write_value(NIX_VERSION).await?;
        }
        if client_version.minor() >= 35 {
            self.writer
                .write_value(&harmonia_protocol::types::TrustLevel::Trusted)
                .await?;
        }
        self.writer.flush().await?;
        Ok(())
    }

    async fn process_logs_write<'s, T: Send + 's>(
        &'s mut self,
        logs: impl ResultLog<Output = DaemonResult<T>> + Send + 's,
    ) -> Result<T, RecoverableError> {
        let value = process_logs(&mut self.writer, logs).await?;
        self.writer.write_value(&RawLogMessage::Last).await?;
        Ok(value)
    }

    async fn process_requests<'s, S>(&'s mut self, mut store: S) -> Result<(), DaemonError>
    where
        S: DaemonStore + 's,
    {
        loop {
            let fut = self.reader.try_read_value::<Request>().boxed();
            let res = fut.await?;
            let Some(request) = res else {
                break;
            };
            let op = request.operation();
            debug!("got op {}", op);
            if let Err(mut err) = self.process_request(&mut store, request).await {
                error!(error = ?err.source, recover=err.can_recover, "error processing request");
                err.source = err.source.fill_operation(op);
                if err.can_recover {
                    self.writer
                        .write_value(&RawLogMessage::Error(err.source.into()))
                        .await?;
                } else {
                    return Err(err.source);
                }
            }
            self.writer.flush().await?;
        }
        store.shutdown().await
    }

    async fn process_request<'s, S>(
        &'s mut self,
        store: &mut S,
        request: Request,
    ) -> Result<(), RecoverableError>
    where
        S: DaemonStore + 's,
    {
        use Request::*;
        match request {
            SetOptions(options) => {
                let logs = store.set_options(&options);
                self.process_logs_write(logs).await?;
            }
            IsValidPath(path) => {
                let logs = store.is_valid_path(&path);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryValidPaths(req) => {
                let logs = store.query_valid_paths(&req.paths, req.substitute);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryPathInfo(path) => {
                let logs = store.query_path_info(&path);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            NarFromPath(path) => {
                let logs = store.nar_from_path(&path);
                let mut logs = pin!(logs);
                while let Some(msg) = logs.next().await {
                    write_log(&mut self.writer, msg).await?;
                }
                let mut reader = pin!(logs.await?);
                self.writer.write_value(&RawLogMessage::Last).await?;
                copy_buf(&mut reader, &mut self.writer)
                    .await
                    .map_err(DaemonError::from)?;
            }
            QueryReferrers(path) => {
                let logs = store.query_referrers(&path);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            AddToStore(req) => {
                let buf_reader = AsyncBufReadCompat::new(&mut self.reader);
                let mut framed = FramedReader::new(buf_reader);
                let logs =
                    store.add_ca_to_store(&req.name, req.cam, &req.refs, req.repair, &mut framed);
                let res = process_logs(&mut self.writer, logs).await;
                let err = framed.drain_all().await;
                let value = res?;
                err?;
                self.writer.write_value(&RawLogMessage::Last).await?;
                self.writer.write_value(&value).await?;
            }
            BuildPaths(req) => {
                let logs = store.build_paths(&req.paths, req.mode);
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            EnsurePath(path) => {
                let logs = store.ensure_path(&path);
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            AddTempRoot(path) => {
                let logs = store.add_temp_root(&path);
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            AddIndirectRoot(path) => {
                let logs = store.add_indirect_root(&path);
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            FindRoots => {
                let logs = store.find_roots();
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            CollectGarbage(req) => {
                let logs = store.collect_garbage(
                    req.action,
                    &req.paths_to_delete,
                    req.ignore_liveness,
                    req.max_freed,
                );
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryAllValidPaths => {
                let logs = store.query_all_valid_paths();
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryPathFromHashPart(hash) => {
                let logs = store.query_path_from_hash_part(&hash);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QuerySubstitutablePaths(paths) => {
                let logs = store.query_substitutable_paths(&paths);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryValidDerivers(path) => {
                let logs = store.query_valid_derivers(&path);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            OptimiseStore => {
                let logs = store.optimise_store();
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            VerifyStore(req) => {
                let logs = store.verify_store(req.check_contents, req.repair);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            BuildDerivation(req) => {
                let (drv_path, drv) = &req.drv;
                let logs = store.build_derivation(drv_path, drv, req.mode);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            AddSignatures(req) => {
                let logs = store.add_signatures(&req.path, &req.signatures);
                self.process_logs_write(logs).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            AddToStoreNar(req) => {
                let buf_reader = AsyncBufReadCompat::new(&mut self.reader);
                let mut framed = FramedReader::new(buf_reader);
                let logs = store.add_to_store_nar(
                    &req.path_info,
                    &mut framed,
                    req.repair,
                    req.dont_check_sigs,
                );
                let res: Result<(), RecoverableError> = async {
                    let mut logs = pin!(logs);
                    while let Some(msg) = logs.next().await {
                        write_log(&mut self.writer, msg).await?;
                    }
                    logs.await.recover()?;
                    Ok(())
                }
                .await;
                let err = framed.drain_all().await;
                res?;
                err?;
                self.writer.write_value(&RawLogMessage::Last).await?;
            }
            QueryMissing(paths) => {
                let logs = store.query_missing(&paths);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            QueryDerivationOutputMap(path) => {
                let logs = store.query_derivation_output_map(&path);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            RegisterDrvOutput(realisation) => {
                let logs = store.register_drv_output(&realisation);
                self.process_logs_write(logs).await?;
            }
            QueryRealisation(output_id) => {
                let logs = store.query_realisation(&output_id);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            AddMultipleToStore(req) => {
                let builder = NixReader::builder().set_version(self.reader.version());
                let buf_reader = AsyncBufReadCompat::new(&mut self.reader);
                let mut framed = FramedReader::new(buf_reader);
                let source = builder.build_buffered(&mut framed);
                let stream = parse_add_multiple_to_store(source).await?;
                let logs = store.add_multiple_to_store(req.repair, req.dont_check_sigs, stream);
                let res: Result<(), RecoverableError> = async {
                    let mut logs = pin!(logs);
                    while let Some(msg) = logs.next().await {
                        write_log(&mut self.writer, msg).await?;
                    }
                    logs.await.recover()?;
                    self.writer.write_value(&RawLogMessage::Last).await?;
                    Ok(())
                }
                .await;
                let err = framed.drain_all().await;
                res?;
                err?;
            }
            AddBuildLog(BaseStorePath(path)) => {
                let buf_reader = AsyncBufReadCompat::new(&mut self.reader);
                let mut framed = FramedReader::new(buf_reader);
                let logs = store.add_build_log(&path, &mut framed);
                let res = process_logs(&mut self.writer, logs).await;
                let err = framed.drain_all().await;
                res?;
                err?;
                self.writer.write_value(&RawLogMessage::Last).await?;
                self.writer.write_value(&IgnoredOne).await?;
            }
            BuildPathsWithResults(req) => {
                let logs = store.build_paths_with_results(&req.paths, req.mode);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
            AddPermRoot(req) => {
                let logs = store.add_perm_root(&req.store_path, &req.gc_root);
                let value = self.process_logs_write(logs).await?;
                self.writer.write_value(&value).await?;
            }
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct DaemonServer<H> {
    handler: H,
    socket_path: PathBuf,
    store_dir: StoreDir,
}

impl<H> DaemonServer<H>
where
    H: HandshakeDaemonStore + Clone + Send + Sync + 'static,
{
    pub fn new(handler: H, socket_path: PathBuf, store_dir: StoreDir) -> Self {
        Self {
            handler,
            socket_path,
            store_dir,
        }
    }

    pub async fn serve(&self) -> Result<(), std::io::Error> {
        if self.socket_path.exists() {
            fs_err::remove_file(&self.socket_path)?;
        }
        if let Some(parent) = self.socket_path.parent() {
            fs_err::create_dir_all(parent)?;
        }

        let listener = UnixListener::bind(&self.socket_path)?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // 0660 allows hydra-group clients without opening ad-hoc build submission to all local users.
            let perms = std::fs::Permissions::from_mode(0o660);
            fs_err::set_permissions(&self.socket_path, perms)?;
        }

        info!("nix daemon listening on {:?}", self.socket_path);

        loop {
            let (stream, _addr) = listener.accept().await?;
            let handler = self.handler.clone();
            let store_dir = self.store_dir.clone();

            tokio::spawn(async move {
                let (reader, writer) = stream.into_split();
                let reader = NixReader::builder()
                    .set_store_dir(&store_dir)
                    .build_buffered(reader);
                let writer = NixWriter::builder().set_store_dir(&store_dir).build(writer);
                let mut conn = DaemonConnection { reader, writer };

                if let Err(e) = conn.handshake().await {
                    error!("handshake error: {e:?}");
                    return;
                }

                let store = {
                    let logs = handler.handshake();
                    let mut logs = std::pin::pin!(logs);
                    while let Some(msg) = futures::StreamExt::next(&mut logs).await {
                        if let Err(e) = conn.writer.write_value(&log_to_raw(msg)).await {
                            error!("handshake log error: {e:?}");
                            return;
                        }
                    }
                    if let Err(e) = conn.writer.write_value(&RawLogMessage::Last).await {
                        error!("handshake terminator error: {e:?}");
                        return;
                    }
                    match logs.await {
                        Ok(s) => s,
                        Err(e) => {
                            error!("store handshake error: {e:?}");
                            return;
                        }
                    }
                };
                if let Err(e) = conn.writer.flush().await {
                    error!("handshake flush error: {e:?}");
                    return;
                }

                if let Err(e) = conn.process_requests(store).await {
                    error!("connection error: {e:?}");
                }
            });
        }
    }
}
