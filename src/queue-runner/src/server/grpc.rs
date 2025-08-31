use std::sync::Arc;

use anyhow::Context as _;
use tokio::{io::AsyncWriteExt as _, sync::mpsc};
use tonic::service::interceptor::InterceptedService;
use tower::ServiceBuilder;
use tracing::Instrument as _;

use crate::{
    config::BindSocket,
    server::grpc::runner_v1::{BuildResultState, StepUpdate},
    state::{Machine, MachineMessage, State},
};
use nix_utils::BaseStore as _;

include!(concat!(env!("OUT_DIR"), "/proto_version.rs"));
use runner_v1::runner_service_server::{RunnerService, RunnerServiceServer};
use runner_v1::{
    BuildResultInfo, BuilderRequest, FetchRequisitesRequest, JoinResponse, LogChunk, NarData,
    PresignedUploadComplete, PresignedUrlRequest, PresignedUrlResponse, RunnerRequest,
    SimplePingMessage, StorePath, StorePaths, VersionCheckRequest, VersionCheckResponse,
    builder_request,
};

type BuilderResult<T> = Result<tonic::Response<T>, tonic::Status>;
type OpenTunnelResponseStream =
    std::pin::Pin<Box<dyn futures::Stream<Item = Result<RunnerRequest, tonic::Status>> + Send>>;
type StreamFileResponseStream =
    std::pin::Pin<Box<dyn futures::Stream<Item = Result<NarData, tonic::Status>> + Send>>;

// there is no reason to make this configurable, it only exists so we ensure the channel is not
// closed. we dont use this to write any actual information.
const BACKWARDS_PING_INTERVAL: u64 = 30;

pub mod runner_v1 {
    // We need to allow pedantic here because of generated code
    #![allow(clippy::pedantic, unused_qualifications)]

    tonic::include_proto!("runner.v1");

    pub(crate) const FILE_DESCRIPTOR_SET: &[u8] =
        tonic::include_file_descriptor_set!("streaming_descriptor");

    impl From<StepStatus> for db::models::StepStatus {
        fn from(item: StepStatus) -> Self {
            match item {
                StepStatus::Preparing => Self::Preparing,
                StepStatus::Connecting => Self::Connecting,
                StepStatus::SeningInputs => Self::SendingInputs,
                StepStatus::Building => Self::Building,
                StepStatus::WaitingForLocalSlot => Self::WaitingForLocalSlot,
                StepStatus::ReceivingOutputs => Self::ReceivingOutputs,
                StepStatus::PostProcessing => Self::PostProcessing,
            }
        }
    }
}

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
    #[tracing::instrument(skip(state), err)]
    pub async fn run(addr: BindSocket, state: Arc<State>) -> anyhow::Result<()> {
        let service = RunnerServiceServer::new(Self {
            state: state.clone(),
        })
        .send_compressed(tonic::codec::CompressionEncoding::Zstd)
        .accept_compressed(tonic::codec::CompressionEncoding::Zstd)
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
            let (client_ca_cert, server_identity) = state
                .cli
                .get_mtls()
                .await
                .context("Failed to get_mtls Certificate and Identity")?;

            let tls = tonic::transport::ServerTlsConfig::new()
                .identity(server_identity)
                .client_ca_root(client_ca_cert);
            server = server.tls_config(tls)?;
        }
        let reflection_service = tonic_reflection::server::Builder::configure()
            .register_encoded_file_descriptor_set(runner_v1::FILE_DESCRIPTOR_SET)
            .build_v1()?;

        let (_health_reporter, health_service) = tonic_health::server::health_reporter();
        let server = server
            .add_service(health_service)
            .add_service(reflection_service)
            .add_service(intercepted_service);

        match addr {
            BindSocket::Tcp(s) => server.serve(s).await?,
            BindSocket::Unix(p) => {
                let uds = tokio::net::UnixListener::bind(p)?;
                let uds_stream = tokio_stream::wrappers::UnixListenerStream::new(uds);
                server.serve_with_incoming(uds_stream).await?;
            }
            BindSocket::ListenFd => {
                let listener = listenfd::ListenFd::from_env()
                    .take_unix_listener(0)?
                    .ok_or_else(|| anyhow::anyhow!("No listenfd found in env"))?;
                listener.set_nonblocking(true)?;
                let listener = tokio_stream::wrappers::UnixListenerStream::new(
                    tokio::net::UnixListener::from_std(listener)?,
                );

                server.serve_with_incoming(listener).await?;
            }
        }

        Ok(())
    }
}

#[tonic::async_trait]
impl RunnerService for Server {
    type OpenTunnelStream = OpenTunnelResponseStream;
    type StreamFileStream = StreamFileResponseStream;
    type StreamFilesStream = StreamFileResponseStream;

    #[tracing::instrument(skip(self, req), err)]
    async fn check_version(
        &self,
        req: tonic::Request<VersionCheckRequest>,
    ) -> BuilderResult<VersionCheckResponse> {
        let req = req.into_inner();
        let server_version = PROTO_API_VERSION;

        if req.version == server_version {
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
        } else {
            tracing::warn!(
                "Version check failed: machine_id={}, hostname={}, client={}, server={}",
                req.machine_id,
                req.hostname,
                req.version,
                server_version
            );
            Ok(tonic::Response::new(VersionCheckResponse {
                compatible: false,
                server_version: server_version.to_string(),
            }))
        }
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
                message: Some(runner_v1::runner_request::Message::Join(JoinResponse {
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
                            message: Some(runner_v1::runner_request::Message::Ping(SimplePingMessage {
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
    ) -> BuilderResult<runner_v1::Empty> {
        use tokio_stream::StreamExt as _;

        let mut stream = req.into_inner();
        let state = self.state.clone();

        let mut out_file: Option<fs_err::tokio::File> = None;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;

            if let Some(ref mut file) = out_file {
                file.write_all(&chunk.data).await?;
            } else {
                let mut file = state
                    .new_log_file(&nix_utils::StorePath::new(&chunk.drv))
                    .await
                    .map_err(|_| tonic::Status::internal("Failed to create log file."))?;
                file.write_all(&chunk.data).await?;
                out_file = Some(file);
            }
        }

        Ok(tonic::Response::new(runner_v1::Empty {}))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn build_result(
        &self,
        req: tonic::Request<tonic::Streaming<NarData>>,
    ) -> BuilderResult<runner_v1::Empty> {
        let stream = req.into_inner();

        // We leak memory if we use the store from state, so we open and close a new
        // connection for each import. This sucks but using the state.store will result in the path
        // not being closed!
        {
            let store = nix_utils::LocalStore::init();
            store
                .import_paths(
                    tokio_stream::StreamExt::map(stream, |s| {
                        s.map(|v| v.chunk.into())
                            .map_err(|e| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, e))
                    }),
                    false,
                )
                .await
        }
        .map_err(|_| tonic::Status::internal("Failed to import path."))?;
        Ok(tonic::Response::new(runner_v1::Empty {}))
    }

    #[tracing::instrument(skip(self), err)]
    async fn build_step_update(
        &self,
        req: tonic::Request<StepUpdate>,
    ) -> BuilderResult<runner_v1::Empty> {
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

        Ok(tonic::Response::new(runner_v1::Empty {}))
    }

    #[tracing::instrument(skip(self, req), fields(machine_id=req.get_ref().machine_id, build_id=req.get_ref().build_id), err)]
    async fn complete_build(
        &self,
        req: tonic::Request<BuildResultInfo>,
    ) -> BuilderResult<runner_v1::Empty> {
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
                if req.result_state() == BuildResultState::Success {
                    let build_output = crate::state::BuildOutput::from(req);
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
                    )
                    .await
                {
                    tracing::error!("Failed to fail step with build_id={build_id}: {e}");
                }
            }
            .in_current_span()
        });

        Ok(tonic::Response::new(runner_v1::Empty {}))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn fetch_drv_requisites(
        &self,
        req: tonic::Request<FetchRequisitesRequest>,
    ) -> BuilderResult<runner_v1::DrvRequisitesMessage> {
        let state = self.state.clone();
        let req = req.into_inner();
        let drv = nix_utils::StorePath::new(&req.path);

        let requisites = state
            .store
            .query_requisites(&[&drv], req.include_outputs)
            .await
            .map_err(|e| {
                tracing::error!("failed to toposort drv e={e}");
                tonic::Status::internal("failed to toposort drv.")
            })?
            .into_iter()
            .map(nix_utils::StorePath::into_base_name)
            .collect();

        Ok(tonic::Response::new(runner_v1::DrvRequisitesMessage {
            requisites,
        }))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn has_path(
        &self,
        req: tonic::Request<StorePath>,
    ) -> BuilderResult<runner_v1::HasPathResponse> {
        let path = nix_utils::StorePath::new(&req.into_inner().path);
        let state = self.state.clone();
        let has_path = state.store.is_valid_path(&path).await;

        Ok(tonic::Response::new(runner_v1::HasPathResponse {
            has_path,
        }))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn stream_file(
        &self,
        req: tonic::Request<StorePath>,
    ) -> BuilderResult<Self::StreamFileStream> {
        let path = nix_utils::StorePath::new(&req.into_inner().path);
        let store = nix_utils::LocalStore::init();
        let (tx, rx) = mpsc::unbounded_channel::<Result<NarData, tonic::Status>>();

        let closure = move |data: &[u8]| {
            let data = Vec::from(data);
            tx.send(Ok(NarData { chunk: data })).is_ok()
        };

        tokio::task::spawn(async move {
            let _ = store.export_paths(&[path], closure);
        });

        Ok(tonic::Response::new(
            Box::pin(tokio_stream::wrappers::UnboundedReceiverStream::new(rx))
                as Self::StreamFileStream,
        ))
    }

    #[tracing::instrument(skip(self, req), err)]
    async fn stream_files(
        &self,
        req: tonic::Request<StorePaths>,
    ) -> BuilderResult<Self::StreamFilesStream> {
        let req = req.into_inner();
        let paths = req
            .paths
            .into_iter()
            .map(|p| nix_utils::StorePath::new(&p))
            .collect::<Vec<_>>();

        let store = nix_utils::LocalStore::init();
        let (tx, rx) = mpsc::unbounded_channel::<Result<NarData, tonic::Status>>();

        let closure = move |data: &[u8]| {
            let data = Vec::from(data);
            tx.send(Ok(NarData { chunk: data })).is_ok()
        };

        tokio::task::spawn(async move {
            let _ = store.export_paths(&paths, closure.clone());
        });

        Ok(tonic::Response::new(
            Box::pin(tokio_stream::wrappers::UnboundedReceiverStream::new(rx))
                as Self::StreamFilesStream,
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
        let _state = self.state.clone();
        let req = req.into_inner();

        let _build_id = uuid::Uuid::parse_str(&req.build_id).map_err(|e| {
            tracing::error!("Failed to parse build_id into uuid: {e}");
            tonic::Status::invalid_argument("build_id is not a valid uuid.")
        })?;
        let _machine_id = uuid::Uuid::parse_str(&req.machine_id).map_err(|e| {
            tracing::error!("Failed to parse machine_id into uuid: {e}");
            tonic::Status::invalid_argument("machine_id is not a valid uuid.")
        })?;

        let remote_store = {
            let remote_stores = _state.remote_stores.read();
            remote_stores
                .first()
                .cloned()
                .ok_or_else(|| tonic::Status::failed_precondition("No remote store configured"))?
        };

        let mut responses = Vec::new();
        for presigned_request in req.request {
            let store_path = nix_utils::StorePath::new(&presigned_request.store_path);

            let presigned_response = remote_store
                .generate_nar_upload_presigned_url(
                    &store_path,
                    &presigned_request.nar_hash,
                    presigned_request.debug_info_build_ids,
                )
                .await
                .map_err(|e| {
                    tracing::error!("Failed to generate presigned URL for {}: {e}", store_path);
                    tonic::Status::internal("Failed to generate presigned URL")
                })?;

            responses.push(runner_v1::PresignedNarResponse {
                store_path: store_path.base_name().to_owned(),
                nar_url: presigned_response.nar_url,
                nar_upload: Some(runner_v1::PresignedUpload {
                    compression_level: presigned_response.nar_upload.get_compression_level_as_i32(),
                    url: presigned_response.nar_upload.url,
                    path: presigned_response.nar_upload.path,
                    compression: presigned_response
                        .nar_upload
                        .compression
                        .as_str()
                        .to_owned(),
                }),
                ls_upload: presigned_response
                    .ls_upload
                    .map(|ls| runner_v1::PresignedUpload {
                        compression_level: ls.get_compression_level_as_i32(),
                        url: ls.url,
                        path: ls.path,
                        compression: ls.compression.as_str().to_owned(),
                    }),
                debug_info_upload: presigned_response
                    .debug_info_upload
                    .into_iter()
                    .map(|p| runner_v1::PresignedUpload {
                        compression_level: p.get_compression_level_as_i32(),
                        url: p.url,
                        path: p.path,
                        compression: p.compression.as_str().to_owned(),
                    })
                    .collect(),
            });
        }

        tracing::debug!("Generated {} presigned URLs", responses.len());
        Ok(tonic::Response::new(PresignedUrlResponse {
            inner: responses,
        }))
    }

    #[tracing::instrument(
        skip(self, req),
        fields(
            build_id=req.get_ref().build_id,
            machine_id=req.get_ref().machine_id,
            store_path=req.get_ref().store_path
        ),
        err,
    )]
    async fn notify_presigned_upload_complete(
        &self,
        req: tonic::Request<PresignedUploadComplete>,
    ) -> BuilderResult<runner_v1::Empty> {
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
                .first()
                .cloned()
                .ok_or_else(|| tonic::Status::failed_precondition("No remote store configured"))?
        };

        let narinfo = binary_cache::NarInfo {
            store_path: nix_utils::StorePath::new(&req.store_path),
            url: req.url.clone(),
            compression: remote_store.cfg.compression,
            file_hash: Some(req.file_hash),
            file_size: Some(req.file_size),
            nar_hash: req.nar_hash,
            nar_size: req.nar_size,
            references: req
                .references
                .into_iter()
                .map(|p| nix_utils::StorePath::new(&p))
                .collect(),
            deriver: req.deriver.map(|p| nix_utils::StorePath::new(&p)),
            ca: req.ca,
            sigs: vec![],
        };
        let store_path = narinfo.store_path.clone();

        let narinfo_url = remote_store
            .upload_narinfo_after_presigned_upload(&self.state.store, narinfo)
            .await
            .map_err(|e| {
                tracing::error!("Failed to upload narinfo for {}: {e}", store_path);
                tonic::Status::internal("Failed to upload narinfo")
            })?;

        tracing::debug!(
            "Presigned upload completed and narinfo uploaded for path: {}, url: {}, size: {} bytes, narinfo: {}",
            store_path,
            req.url,
            req.file_size,
            narinfo_url
        );

        Ok(tonic::Response::new(runner_v1::Empty {}))
    }
}
