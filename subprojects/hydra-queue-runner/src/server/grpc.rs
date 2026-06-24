use std::sync::Arc;

use harmonia_store_path::StorePath;
/// Errors from gRPC server setup and serving.
#[derive(Debug, thiserror::Error)]
pub enum ServerError {
    #[error("gRPC transport error")]
    Transport(#[from] tonic::transport::Error),
    #[error("loading mTLS certificate and identity")]
    Mtls(#[from] crate::config::ConfigError),
    #[error("reflection service: {0}")]
    Reflection(#[from] tonic_reflection::server::Error),
}
use tokio::sync::mpsc;
use tonic::service::interceptor::InterceptedService;
use tower::ServiceBuilder;
use tracing::Instrument as _;

use crate::state::{Machine, MachineMessage, State};
use hydra_proto::ProtoStorePath;
use hydra_proto::{
    BuildResultInfo, BuilderRequest, JoinResponse, LogChunk, MultipartPartsRequest,
    MultipartPartsResponse, PROTO_API_VERSION, PresignedUploadComplete, PresignedUrlRequest,
    PresignedUrlResponse, RunnerRequest, SimplePingMessage, StepUpdate, VersionCheckRequest,
    VersionCheckResponse, builder_request,
    runner_service_server::{RunnerService, RunnerServiceServer},
};

fn multipart_to_proto(mp: binary_cache::PresignedMultipart) -> hydra_proto::MultipartUpload {
    hydra_proto::MultipartUpload {
        upload_id: mp.upload_id,
        part_size: mp.part_size,
        parts: mp
            .parts
            .into_iter()
            .map(|p| hydra_proto::MultipartPart {
                part_number: p.part_number,
                url: p.url,
            })
            .collect(),
    }
}

type BuilderResult<T> = Result<tonic::Response<T>, tonic::Status>;
type OpenTunnelResponseStream =
    std::pin::Pin<Box<dyn futures::Stream<Item = Result<RunnerRequest, tonic::Status>> + Send>>;
type FetchPathsResponseStream = std::pin::Pin<
    Box<dyn futures::Stream<Item = Result<hydra_proto::AddToStoreRequest, tonic::Status>> + Send>,
>;
type CompressionDecoder<R> = async_compression::tokio::bufread::ZstdDecoder<R>;

// there is no reason to make this configurable, it only exists so we ensure the channel is not
// closed. we dont use this to write any actual information.
const BACKWARDS_PING_INTERVAL: u64 = 30;

fn match_for_io_error(err_status: &tonic::Status) -> Option<&std::io::Error> {
    let mut err: &(dyn std::error::Error + 'static) = err_status;

    loop {
        if let Some(io_err) = err.downcast_ref::<std::io::Error>() {
            return Some(io_err);
        }

        // h2::Error do not expose std::io::Error with `source()`
        // https://github.com/hyperium/h2/pull/462
        if let Some(h2_err) = err.downcast_ref::<h2::Error>()
            && let Some(io_err) = h2_err.get_io()
        {
            return Some(io_err);
        }

        err = err.source()?;
    }
}

#[tracing::instrument(skip(state, msg))]
fn handle_message(state: &Arc<State>, msg: builder_request::Message) {
    match msg {
        // at this point in time, builder already joined, so this message can be ignored
        builder_request::Message::Join(_) => (),
        builder_request::Message::Ping(msg) => {
            tracing::debug!("new ping: {msg:?}");
            let Ok(machine_id) = uuid::Uuid::parse_str(&msg.machine_id) else {
                return;
            };
            if let Some(m) = state.machines.get_machine_by_id(machine_id) {
                m.stats.store_ping(&msg);
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct CheckAuthInterceptor {
    config: crate::config::App,
}

impl tonic::service::Interceptor for CheckAuthInterceptor {
    fn call(&mut self, req: tonic::Request<()>) -> Result<tonic::Request<()>, tonic::Status> {
        if self.config.has_token_list() {
            match req.metadata().get("authorization") {
                Some(t)
                    if self.config.check_if_contains_token(
                        t.to_str()
                            .map_err(|_| tonic::Status::unauthenticated("No valid auth token"))?
                            .strip_prefix("Bearer ")
                            .ok_or_else(|| tonic::Status::unauthenticated("No valid auth token"))?,
                    ) =>
                {
                    Ok(req)
                }
                _ => Err(tonic::Status::unauthenticated("No valid auth token")),
            }
        } else {
            Ok(req)
        }
    }
}

#[allow(missing_debug_implementations)]
#[derive(Clone)]
pub struct Server {
    state: Arc<State>,
}

impl Server {
    /// Serve on a pre-bound TCP listener.
    #[tracing::instrument(skip(listener, state), err)]
    pub async fn run(
        listener: tokio::net::TcpListener,
        state: Arc<State>,
    ) -> Result<(), ServerError> {
        let stream = tokio_stream::wrappers::TcpListenerStream::new(listener);
        Self::serve_incoming(stream, state).await
    }

    /// Serve on a Unix socket listener.
    #[tracing::instrument(skip(listener, state), err)]
    pub async fn run_unix(
        listener: tokio::net::UnixListener,
        state: Arc<State>,
    ) -> Result<(), ServerError> {
        let stream = tokio_stream::wrappers::UnixListenerStream::new(listener);
        Self::serve_incoming(stream, state).await
    }

    async fn serve_incoming<S, IO, IE>(incoming: S, state: Arc<State>) -> Result<(), ServerError>
    where
        S: futures_util::Stream<Item = Result<IO, IE>>,
        IO: tokio::io::AsyncRead
            + tokio::io::AsyncWrite
            + tonic::transport::server::Connected
            + Unpin
            + Send
            + 'static,
        // Required by tonic's `serve_with_incoming` API. We cannot replace this bound with
        // something else.
        IE: Into<Box<dyn std::error::Error + Send + Sync>>,
    {
        let service = RunnerServiceServer::new(Self {
            state: state.clone(),
        })
        .max_decoding_message_size(50 * 1024 * 1024)
        .max_encoding_message_size(50 * 1024 * 1024);
        let intercepted_service = InterceptedService::new(
            service,
            CheckAuthInterceptor {
                config: state.config.clone(),
            },
        );

        let mut server = tonic::transport::Server::builder().layer(
            ServiceBuilder::new()
                .layer(
                    tower_http::trace::TraceLayer::new_for_grpc().make_span_with(
                        tower_http::trace::DefaultMakeSpan::new()
                            .level(tracing::Level::INFO)
                            .include_headers(false),
                    ),
                )
                .map_request(hydra_tracing::propagate::accept_trace),
        );

        if state.cli.mtls_enabled() {
            tracing::info!("Using mtls");
            let (client_ca_cert, server_identity) = state.cli.get_mtls().await?;

            let tls = tonic::transport::ServerTlsConfig::new()
                .identity(server_identity)
                .client_ca_root(client_ca_cert);
            server = server.tls_config(tls)?;
        }
        let reflection_service = tonic_reflection::server::Builder::configure()
            .register_encoded_file_descriptor_set(hydra_proto::FILE_DESCRIPTOR_SET)
            .build_v1()?;

        let (_health_reporter, health_service) = tonic_health::server::health_reporter();
        server
            .add_service(health_service)
            .add_service(reflection_service)
            .add_service(intercepted_service)
            .serve_with_incoming(incoming)
            .await?;

        Ok(())
    }
}

#[tonic::async_trait]
impl RunnerService for Server {
    type OpenTunnelStream = OpenTunnelResponseStream;
    type FetchPathsStream = FetchPathsResponseStream;

    #[tracing::instrument(skip(self, req), err)]
    async fn check_version(
        &self,
        req: tonic::Request<VersionCheckRequest>,
    ) -> BuilderResult<VersionCheckResponse> {
        let req = req.into_inner();
        let server_version = PROTO_API_VERSION;

        if req.version != server_version {
            tracing::warn!(
                "Version check failed: machine_id={}, hostname={}, client={}, server={}",
                req.machine_id,
                req.hostname,
                req.version,
                server_version
            );
            return Ok(tonic::Response::new(VersionCheckResponse {
                compatible: false,
                server_version: server_version.to_string(),
            }));
        }

        let our_store_dir = self.state.connector.store_dir().to_string();
        if req.store_dir != our_store_dir {
            return Err(tonic::Status::failed_precondition(format!(
                "Store dir mismatch: builder has `{}`, server has `{}`",
                req.store_dir, our_store_dir
            )));
        }

        tracing::info!(
            "Version check passed: machine_id={}, hostname={}, client={}, server={}",
            req.machine_id,
            req.hostname,
            req.version,
            server_version
        );
        Ok(tonic::Response::new(VersionCheckResponse {
            compatible: true,
            server_version: server_version.to_string(),
        }))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn open_tunnel(
        &self,
        req: tonic::Request<tonic::Streaming<BuilderRequest>>,
    ) -> BuilderResult<Self::OpenTunnelStream> {
        use tokio_stream::StreamExt as _;

        let mut stream = req.into_inner();
        let (input_tx, mut input_rx) = mpsc::channel::<MachineMessage>(128);
        let use_presigned_uploads = self.state.config.use_presigned_uploads();
        let forced_substituters = self.state.config.get_forced_substituters();
        let machine = match stream.next().await {
            Some(Ok(m)) => match m.message {
                Some(builder_request::Message::Join(v)) => {
                    match Machine::new(v, input_tx, use_presigned_uploads, &forced_substituters) {
                        Ok(m) => Some(m),
                        Err(e) => {
                            tracing::error!("Rejecting new machine creation: {e}");
                            return Err(tonic::Status::invalid_argument("Machine is not valid"));
                        }
                    }
                }
                _ => None,
            },
            Some(Err(e)) => {
                tracing::error!("Bad message in stream: {e}");
                None
            }
            _ => None,
        };
        let Some(machine) = machine else {
            return Err(tonic::Status::invalid_argument("No Ping message was sent"));
        };

        let state = self.state.clone();
        let machine_id = state.insert_machine(machine.clone()).await;
        tracing::info!("Registered new machine: machine_id={machine_id} machine={machine}",);

        let (output_tx, output_rx) = mpsc::channel(128);
        if let Err(e) = output_tx
            .send(Ok(RunnerRequest {
                message: Some(hydra_proto::runner_request::Message::Join(JoinResponse {
                    machine_id: machine_id.to_string(),
                    max_concurrent_downloads: state.config.get_max_concurrent_downloads(),
                })),
            }))
            .await
        {
            tracing::error!("Failed to send join response machine_id={machine_id} e={e}");
            return Err(tonic::Status::internal("Failed to send join Response."));
        }

        let mut ping_interval =
            tokio::time::interval(std::time::Duration::from_secs(BACKWARDS_PING_INTERVAL));
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = ping_interval.tick() => {
                        let msg = RunnerRequest {
                            message: Some(hydra_proto::runner_request::Message::Ping(SimplePingMessage {
                                message: "ping".into(),
                            }))
                        };
                        if let Err(e) = output_tx.send(Ok(msg)).await {
                            tracing::error!("Failed to send message to machine={machine_id} e={e}");
                            state.remove_machine(machine_id).await;
                            break
                        }
                    },
                    msg = input_rx.recv() => {
                        if let Some(msg) = msg {
                            if let Err(e) = output_tx.send(Ok(msg.into_request())).await {
                                tracing::error!("Failed to send message to machine={machine_id} e={e}");
                                state.remove_machine(machine_id).await;
                                break
                            }
                        } else {
                            state.remove_machine(machine_id).await;
                            break
                        }
                    },
                    msg = stream.next() => match msg.map(|v| v.map(|v| v.message)) {
                        Some(Ok(Some(msg))) => handle_message(&state, msg),
                        Some(Ok(None)) => (), // empty meesage can be ignored
                        Some(Err(err)) => {
                            if let Some(io_err) = match_for_io_error(&err)
                                && io_err.kind() == std::io::ErrorKind::BrokenPipe {
                                    tracing::error!("client disconnected: broken pipe: machine={machine_id} hostname={}", machine.hostname);
                                    state.remove_machine(machine_id).await;
                                    break;
                                }

                            match output_tx.send(Err(err)).await {
                                Ok(()) => (),
                                Err(_err) => {
                                    state.remove_machine(machine_id).await;
                                    break
                                }
                            }
                        },
                        None => {
                            state.remove_machine(machine_id).await;
                            break
                        }
                    }
                }
            }
        });

        Ok(tonic::Response::new(
            Box::pin(tokio_stream::wrappers::ReceiverStream::new(output_rx))
                as Self::OpenTunnelStream,
        ))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn build_log(
        &self,
        req: tonic::Request<tonic::Streaming<LogChunk>>,
    ) -> BuilderResult<hydra_proto::Empty> {
        use tokio_stream::StreamExt as _;

        let stream = req.into_inner();
        let state = self.state.clone();

        let mut mapped = stream.map(|result| {
            result
                .map(|chunk| (chunk.drv, bytes::Bytes::from(chunk.data)))
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, e))
        });

        let (drv, first_data) = mapped
            .next()
            .await
            .ok_or_else(|| tonic::Status::internal("Empty stream"))??;

        let file = state
            .new_log_file(
                &drv.ok_or_else(|| tonic::Status::invalid_argument("missing drv"))?
                    .into(),
            )
            .await
            .map_err(|e| tonic::Status::internal(format!("Failed to create log file: {e}")))?;

        let first = tokio_stream::iter(vec![Ok::<_, std::io::Error>(first_data)]);
        let rest = mapped.map(|r| r.map(|(_, data)| data));
        let full_stream = first.chain(rest);

        let reader = tokio_util::io::StreamReader::new(full_stream);
        let mut decoder = CompressionDecoder::new(reader);
        let mut file: fs_err::tokio::File = file;

        tokio::io::copy(&mut decoder, &mut file)
            .await
            .map_err(|e| tonic::Status::internal(format!("Failed to write log file: {e}")))?;

        Ok(tonic::Response::new(hydra_proto::Empty {}))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn build_result(
        &self,
        req: tonic::Request<tonic::Streaming<hydra_proto::AddToStoreRequest>>,
    ) -> BuilderResult<hydra_proto::Empty> {
        let mut conn = self
            .state
            .connector
            .connect()
            .await
            .map_err(|e| tonic::Status::internal(format!("daemon connection failed: {e}")))?;
        store_transfer::import::import(&mut conn, req.into_inner())
            .await
            .map_err(|e| tonic::Status::internal(format!("import error: {e}")))?;
        Ok(tonic::Response::new(hydra_proto::Empty {}))
    }

    #[tracing::instrument(skip(self), err)]
    async fn build_step_update(
        &self,
        req: tonic::Request<StepUpdate>,
    ) -> BuilderResult<hydra_proto::Empty> {
        let state = self.state.clone();

        let req = req.into_inner();
        let build_id = uuid::Uuid::parse_str(&req.build_id).map_err(|e| {
            tracing::error!("Failed to parse build_id into uuid: {e}");
            tonic::Status::invalid_argument("build_id is not a valid uuid.")
        })?;
        let machine_id = uuid::Uuid::parse_str(&req.machine_id).map_err(|e| {
            tracing::error!("Failed to parse machine_id into uuid: {e}");
            tonic::Status::invalid_argument("machine_id is not a valid uuid.")
        })?;
        let step_status = db::models::StepStatus::from(req.step_status());

        tokio::spawn({
            async move {
                if let Err(e) = state
                    .update_build_step(
                        build_id,
                        machine_id,
                        step_status,
                    )
                    .await
                {
                    tracing::error!(
                        "Failed to update build step with build_id={build_id:?} step_status={step_status:?}: {e}"
                    );
                }
            }.in_current_span()
        });

        Ok(tonic::Response::new(hydra_proto::Empty {}))
    }

    #[tracing::instrument(skip(self, req), fields(machine_id=req.get_ref().machine_id, build_id=req.get_ref().build_id), err)]
    async fn complete_build(
        &self,
        req: tonic::Request<BuildResultInfo>,
    ) -> BuilderResult<hydra_proto::Empty> {
        let state = self.state.clone();

        let req = req.into_inner();
        let build_id = uuid::Uuid::parse_str(&req.build_id).map_err(|e| {
            tracing::error!("Failed to parse build_id into uuid: {e}");
            tonic::Status::invalid_argument("build_id is not a valid uuid.")
        })?;
        let machine_id = uuid::Uuid::parse_str(&req.machine_id).map_err(|e| {
            tracing::error!("Failed to parse machine_id into uuid: {e}");
            tonic::Status::invalid_argument("machine_id is not a valid uuid.")
        })?;

        tokio::spawn({
            async move {
                if req.result_state() == hydra_proto::BuildResultState::Success {
                    let build_output = match crate::state::BuildOutput::from_grpc(req) {
                        Ok(output) => output,
                        Err(e) => {
                            tracing::error!("Failed to parse build output: {e}");
                            return;
                        }
                    };
                    if let Err(e) = state
                        .succeed_step_by_uuid(build_id, machine_id, build_output)
                        .await
                    {
                        tracing::error!(
                            "Failed to mark step with build_id={build_id} as done: {e}"
                        );
                    }
                } else if let Err(e) = state
                    .fail_step_by_uuid(
                        build_id,
                        machine_id,
                        req.result_state().into(),
                        crate::state::BuildTimings::new(
                            req.import_time_ms,
                            req.build_time_ms,
                            req.upload_time_ms,
                        ),
                        req.error_msg.clone(),
                    )
                    .await
                {
                    tracing::error!("Failed to fail step with build_id={build_id}: {e}");
                }
            }
            .in_current_span()
        });

        Ok(tonic::Response::new(hydra_proto::Empty {}))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn fetch_requisites(
        &self,
        req: tonic::Request<hydra_proto::StorePaths>,
    ) -> BuilderResult<hydra_proto::RequisitesResponse> {
        let state = self.state.clone();
        let paths: Vec<_> = req.into_inner().paths.into_iter().map(|p| p.0).collect();

        let requisites: Vec<ProtoStorePath> = state
            .store
            .query_closure_infos(paths)
            .await
            .map_err(|e| {
                tracing::error!("failed to compute closure e={e}");
                tonic::Status::internal("failed to compute closure.")
            })?
            .into_iter()
            .map(|vpi| ProtoStorePath(vpi.path))
            .collect();

        Ok(tonic::Response::new(hydra_proto::RequisitesResponse {
            requisites,
        }))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn has_path(
        &self,
        req: tonic::Request<ProtoStorePath>,
    ) -> BuilderResult<hydra_proto::HasPathResponse> {
        let path = req.into_inner().0;
        let state = self.state.clone();
        let has_path: bool = state
            .store
            .is_valid_path(&path)
            .await
            .map_err(|e| tonic::Status::internal(format!("is_valid_path failed: {e}")))?;

        Ok(tonic::Response::new(hydra_proto::HasPathResponse {
            has_path,
        }))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn fetch_paths(
        &self,
        req: tonic::Request<hydra_proto::StorePaths>,
    ) -> BuilderResult<Self::FetchPathsStream> {
        let paths: Vec<_> = req.into_inner().paths.into_iter().map(|p| p.0).collect();

        // Reuse one daemon connection for the whole path-info loop.
        let mut conn = self
            .state
            .store
            .connect()
            .await
            .map_err(|e| tonic::Status::internal(format!("daemon connection: {e}")))?;
        let mut infos = hashbrown::HashMap::with_capacity(paths.len());
        for path in &paths {
            let info = daemon_client_utils::query_path_info(&mut conn, path)
                .await
                .map_err(|e| tonic::Status::internal(format!("query_path_info failed: {e}")))?
                .map(|vpi| vpi.info)
                .ok_or_else(|| tonic::Status::not_found(format!("path '{path}' is not valid")))?;
            infos.insert(path.clone(), info);
        }

        let (tx, rx) = mpsc::unbounded_channel();

        tokio::spawn({
            let connector = self.state.connector.clone();
            async move {
                let mut conn = match connector.connect().await {
                    Ok(c) => c,
                    Err(e) => {
                        tracing::error!("export failed: daemon connection: {e}");
                        return;
                    }
                };
                if let Err(e) = store_transfer::export::export(&mut conn, &paths, &infos, &tx).await
                {
                    tracing::error!("export failed: {e}");
                }
            }
        });

        Ok(tonic::Response::new(
            Box::pin(tokio_stream::wrappers::UnboundedReceiverStream::new(rx))
                as Self::FetchPathsStream,
        ))
    }

    #[tracing::instrument(
        skip(self, req),
        fields(
            build_id=req.get_ref().build_id,
            machine_id=req.get_ref().machine_id
        ),
        err
    )]
    async fn request_presigned_url(
        &self,
        req: tonic::Request<PresignedUrlRequest>,
    ) -> BuilderResult<PresignedUrlResponse> {
        let state = self.state.clone();
        let req = req.into_inner();

        let build_id = uuid::Uuid::parse_str(&req.build_id).map_err(|e| {
            tracing::error!("Failed to parse build_id into uuid: {e}");
            tonic::Status::invalid_argument("build_id is not a valid uuid.")
        })?;
        let machine_id = uuid::Uuid::parse_str(&req.machine_id).map_err(|e| {
            tracing::error!("Failed to parse machine_id into uuid: {e}");
            tonic::Status::invalid_argument("machine_id is not a valid uuid.")
        })?;

        // Only a builder that owns a running job for this build may mint an
        // upload URL, so a stale or reclaimed-from builder cannot publish
        // outputs for a step it no longer owns.
        let machine = state
            .machines
            .get_machine_by_id(machine_id)
            .ok_or_else(|| tonic::Status::not_found("Machine not found"))?;
        machine
            .get_job_drv_for_build_id(build_id)
            .ok_or_else(|| tonic::Status::not_found("Job not found for this build_id"))?;

        let remote_store = {
            let remote_stores = state.remote_stores.read();
            remote_stores
                .iter()
                .find_map(|s| match s {
                    crate::state::RemoteStoreBackend::S3(s) => Some(s.clone()),
                    crate::state::RemoteStoreBackend::NixCopy(_) => None,
                })
                .ok_or_else(|| tonic::Status::failed_precondition("No remote store configured"))?
        };

        let requests = req
            .request
            .into_iter()
            .map(|r| StorePath::from_base_path(&r.store_path).map(|p| (p, r)))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| tonic::Status::invalid_argument(format!("bad store path: {e}")))?;

        // Only mint upload URLs for paths missing from the remote cache.
        // Presigning the whole closure makes the builder re-compress and
        // re-PUT already-cached deps (glibc, gcc, …) on every build while it
        // holds its build slot, which collapses throughput.
        let missing: hashbrown::HashSet<StorePath> = remote_store
            .query_missing_paths(requests.iter().map(|(p, _)| p.clone()).collect())
            .await
            .into_iter()
            .collect();

        let mut responses = Vec::new();
        for (store_path, presigned_request) in requests {
            if !missing.contains(&store_path) {
                continue;
            }

            let proto_hash = presigned_request
                .nar_hash
                .ok_or_else(|| tonic::Status::invalid_argument("missing nar_hash"))?;
            let hash: harmonia_utils_hash::Hash = proto_hash
                .try_into()
                .map_err(|e: &str| tonic::Status::invalid_argument(e))?;
            let nar_hash: harmonia_store_path_info::NarHash = hash
                .try_into()
                .map_err(|_| tonic::Status::invalid_argument("nar_hash is not sha256"))?;
            let presigned_response = remote_store
                .generate_nar_upload_presigned_url(
                    &store_path,
                    &nar_hash,
                    presigned_request.nar_size,
                    presigned_request.debug_info_build_ids,
                )
                .await
                .map_err(|e| {
                    tracing::error!("Failed to generate presigned URL for {}: {e}", store_path);
                    tonic::Status::internal("Failed to generate presigned URL")
                })?;

            responses.push(hydra_proto::PresignedNarResponse {
                store_path: store_path.to_string(),
                nar_url: presigned_response.nar_url,
                nar_upload: Some(hydra_proto::PresignedUpload {
                    compression_level: presigned_response.nar_upload.get_compression_level_as_i32(),
                    url: presigned_response.nar_upload.url,
                    path: presigned_response.nar_upload.path,
                    compression: presigned_response
                        .nar_upload
                        .compression
                        .as_str()
                        .to_owned(),
                    multipart: presigned_response
                        .nar_upload
                        .multipart
                        .map(multipart_to_proto),
                }),
                ls_upload: presigned_response
                    .ls_upload
                    .map(|ls| hydra_proto::PresignedUpload {
                        compression_level: ls.get_compression_level_as_i32(),
                        url: ls.url,
                        path: ls.path,
                        compression: ls.compression.as_str().to_owned(),
                        multipart: None,
                    }),
                debug_info_upload: presigned_response
                    .debug_info_upload
                    .into_iter()
                    .map(|p| hydra_proto::PresignedUpload {
                        compression_level: p.get_compression_level_as_i32(),
                        url: p.url,
                        path: p.path,
                        compression: p.compression.as_str().to_owned(),
                        multipart: None,
                    })
                    .collect(),
            });
        }

        tracing::debug!("Generated {} presigned URLs", responses.len());
        Ok(tonic::Response::new(PresignedUrlResponse {
            inner: responses,
        }))
    }

    async fn request_multipart_parts(
        &self,
        req: tonic::Request<MultipartPartsRequest>,
    ) -> BuilderResult<MultipartPartsResponse> {
        let req = req.into_inner();

        uuid::Uuid::parse_str(&req.build_id)
            .map_err(|_| tonic::Status::invalid_argument("build_id is not a valid uuid."))?;
        uuid::Uuid::parse_str(&req.machine_id)
            .map_err(|_| tonic::Status::invalid_argument("machine_id is not a valid uuid."))?;
        if req.num_parts == 0 {
            return Err(tonic::Status::invalid_argument(
                "num_parts must be positive",
            ));
        }

        let remote_store = {
            let remote_stores = self.state.remote_stores.read();
            remote_stores
                .iter()
                .find_map(|s| match s {
                    crate::state::RemoteStoreBackend::S3(s) => Some(s.clone()),
                    crate::state::RemoteStoreBackend::NixCopy(_) => None,
                })
                .ok_or_else(|| tonic::Status::failed_precondition("No remote store configured"))?
        };

        let parts = remote_store
            .presign_more_multipart_parts(
                &req.object_key,
                &req.upload_id,
                req.start_part_number,
                req.num_parts,
            )
            .map_err(|e| {
                tracing::error!("Failed to presign more multipart parts: {e}");
                tonic::Status::internal("Failed to presign multipart parts")
            })?;

        Ok(tonic::Response::new(MultipartPartsResponse {
            parts: parts
                .into_iter()
                .map(|p| hydra_proto::MultipartPart {
                    part_number: p.part_number,
                    url: p.url,
                })
                .collect(),
        }))
    }

    #[tracing::instrument(
        skip(self, req),
        fields(
            build_id=req.get_ref().build_id,
            machine_id=req.get_ref().machine_id,
        ),
        err,
    )]
    async fn notify_presigned_upload_complete(
        &self,
        req: tonic::Request<PresignedUploadComplete>,
    ) -> BuilderResult<hydra_proto::Empty> {
        let state = self.state.clone();
        let req = req.into_inner();

        let build_id = uuid::Uuid::parse_str(&req.build_id).map_err(|e| {
            tracing::error!("Failed to parse build_id into uuid: {e}");
            tonic::Status::invalid_argument("build_id is not a valid uuid.")
        })?;
        let machine_id = uuid::Uuid::parse_str(&req.machine_id).map_err(|e| {
            tracing::error!("Failed to parse machine_id into uuid: {e}");
            tonic::Status::invalid_argument("machine_id is not a valid uuid.")
        })?;

        let machine = state
            .machines
            .get_machine_by_id(machine_id)
            .ok_or_else(|| tonic::Status::not_found("Machine not found"))?;
        let _job = machine
            .get_job_drv_for_build_id(build_id)
            .ok_or_else(|| tonic::Status::not_found("Job not found for this build_id"))?;

        let remote_store = {
            let remote_stores = state.remote_stores.read();
            remote_stores
                .iter()
                .find_map(|s| match s {
                    crate::state::RemoteStoreBackend::S3(s) => Some(s.clone()),
                    crate::state::RemoteStoreBackend::NixCopy(_) => None,
                })
                .ok_or_else(|| tonic::Status::failed_precondition("No remote store configured"))?
        };

        let proto_nar_info = req
            .nar_info
            .ok_or_else(|| tonic::Status::invalid_argument("missing nar_info"))?;

        let mut narinfo: binary_cache::NarInfo = proto_nar_info
            .try_into()
            .map_err(|e: hydra_proto::NarInfoConvertError| tonic::Status::invalid_argument(e.0))?;

        if &narinfo.info.info.store_dir != self.state.connector.store_dir() {
            return Err(tonic::Status::invalid_argument(format!(
                "store_dir mismatch: expected {}, got {}",
                self.state.connector.store_dir(),
                narinfo.info.info.store_dir
            )));
        }

        // The cache signs and formats narinfos with its own configured store
        // dir; for those signatures to match the uploaded paths it must agree
        // with the local store (the narinfo was just checked against it above).
        debug_assert_eq!(
            &remote_store.cfg.store_dir,
            self.state.connector.store_dir()
        );

        let store_path = narinfo.path.clone();

        // Override compression from server config
        narinfo.info.compression = Some(remote_store.cfg.compression.as_str().to_owned());

        let url = narinfo.info.url.clone();
        let size = narinfo.info.download_size;

        // The content-addressed nar/<hash> object is written at most once
        // (If-None-Match). The narinfo is always written, but it must describe
        // the stored object: when the NAR was already present, its bytes are a
        // different (equally valid) compression than this upload's, so the
        // narinfo writer recomputes FileHash/FileSize from the object. For a
        // single PUT the builder reports this; for multipart the conditional
        // Complete here decides it.
        let mut nar_already_present = req.nar_already_present;

        // Multipart NAR objects only exist on S3 once finalised; do it here,
        // before upload_narinfo_after_presigned_upload HEAD-checks the object.
        if let Some(mp) = req.multipart {
            let parts = mp
                .parts
                .into_iter()
                .map(|p| binary_cache::CompletedPart {
                    part_number: p.part_number,
                    etag: p.etag,
                })
                .collect();
            match remote_store
                .complete_multipart_upload(&mp.object_key, &mp.upload_id, parts)
                .await
            {
                Ok(binary_cache::WriteOutcome::Created) => {}
                Ok(binary_cache::WriteOutcome::AlreadyExists) => {
                    nar_already_present = true;
                }
                // CompleteMultipartUpload is not idempotent and must not be
                // aborted: aborting frees the uploadId, so a builder retry would
                // see 404 NoSuchUpload and never finalise. If the object is
                // present the completion effectively succeeded (treat as
                // already-present); otherwise return a retryable error so the
                // builder retries with the same (still-live) uploadId.
                Err(e) => {
                    if remote_store
                        .head_object(&mp.object_key)
                        .await
                        .unwrap_or(false)
                    {
                        tracing::warn!(
                            "complete_multipart_upload for {store_path} reported {e}, but the object is present; treating as already complete"
                        );
                        nar_already_present = true;
                    } else {
                        tracing::error!(
                            "Failed to complete multipart upload for {store_path}: {e}"
                        );
                        return Err(tonic::Status::internal(
                            "Failed to complete multipart upload",
                        ));
                    }
                }
            }
        }

        let narinfo_url = remote_store
            .upload_narinfo_after_presigned_upload(narinfo, nar_already_present)
            .await
            .map_err(|e| {
                tracing::error!("Failed to upload narinfo for {}: {e}", store_path);
                tonic::Status::internal("Failed to upload narinfo")
            })?;

        tracing::debug!(
            "Presigned upload completed and narinfo uploaded for path: {}, url: {:?}, size: {:?} bytes, narinfo: {}",
            store_path,
            url,
            size,
            narinfo_url
        );

        Ok(tonic::Response::new(hydra_proto::Empty {}))
    }
}
