use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::Context as _;
use tonic::{Request, service::interceptor::InterceptedService, transport::Channel};

/// HTTP/2 keep-alive interval.  Tonic sends HTTP/2 PING frames at this
/// cadence so both sides detect a dead TCP connection promptly.
const HTTP2_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);

/// How long to wait for an HTTP/2 PING ACK before considering the
/// connection dead.
const HTTP2_KEEPALIVE_TIMEOUT: Duration = Duration::from_secs(20);

/// If no message arrives from the queue runner within this window the
/// stream is considered dead and the builder will reconnect.
const STREAM_RECV_TIMEOUT: Duration = Duration::from_secs(90);

use runner_v1::{
    BuilderRequest, VersionCheckRequest, builder_request, runner_request,
    runner_service_client::RunnerServiceClient,
};

pub mod runner_v1 {
    // We need to allow pedantic here because of generated code
    #![allow(clippy::pedantic, unused_qualifications)]

    tonic::include_proto!("runner.v1");
}

#[derive(Debug, Clone)]
pub enum BuilderInterceptor {
    Token {
        token: tonic::metadata::MetadataValue<tonic::metadata::Ascii>,
    },
    Noop,
}

impl tonic::service::Interceptor for BuilderInterceptor {
    fn call(&mut self, request: Request<()>) -> Result<Request<()>, tonic::Status> {
        let mut request = hydra_tracing::propagate::send_trace(request).map_err(|e| *e)?;

        if let Self::Token { token } = self {
            request
                .metadata_mut()
                .insert("authorization", token.clone());
        }

        Ok(request)
    }
}

pub type BuilderClient = RunnerServiceClient<InterceptedService<Channel, BuilderInterceptor>>;

impl BuilderClient {
    #[tracing::instrument(skip(self, store_paths), err)]
    pub async fn request_presigned_urls(
        &mut self,
        build_id: &str,
        machine_id: &str,
        store_paths: Vec<(nix_utils::StorePath, String, Vec<String>)>,
    ) -> anyhow::Result<Vec<runner_v1::PresignedNarResponse>> {
        use runner_v1::{PresignedNarRequest, PresignedUrlRequest};

        let request = store_paths
            .into_iter()
            .map(|(path, nar_hash, build_ids)| PresignedNarRequest {
                store_path: path.to_string(),
                nar_hash,
                debug_info_build_ids: build_ids,
            })
            .collect::<Vec<_>>();

        let response = self
            .request_presigned_url(PresignedUrlRequest {
                build_id: build_id.to_owned(),
                machine_id: machine_id.to_owned(),
                request,
            })
            .await
            .context("Failed to request presigned URLs")?;

        Ok(response.into_inner().inner)
    }
}

#[tracing::instrument(err)]
pub async fn init_client(cli: &crate::config::Cli) -> anyhow::Result<BuilderClient> {
    if !cli.mtls_configured_correctly() {
        tracing::error!(
            "mtls configured inproperly, please pass all options: \
            server_root_ca_cert_path, client_cert_path, client_key_path and domain_name!"
        );
        return Err(anyhow::anyhow!("Configuration issue"));
    }

    tracing::info!("connecting to {}", cli.gateway_endpoint);
    let channel = if cli.mtls_enabled() {
        tracing::info!("mtls is enabled");
        let (server_root_ca_cert, client_identity, domain_name) = cli
            .get_mtls()
            .await
            .context("Failed to get_mtls Certificate and Identity")?;
        let tls = tonic::transport::ClientTlsConfig::new()
            .domain_name(domain_name)
            .ca_certificate(server_root_ca_cert)
            .identity(client_identity);

        Channel::builder(cli.gateway_endpoint.parse()?)
            .http2_keep_alive_interval(HTTP2_KEEPALIVE_INTERVAL)
            .keep_alive_timeout(HTTP2_KEEPALIVE_TIMEOUT)
            .keep_alive_while_idle(true)
            .tls_config(tls)
            .context("Failed to attach tls config")?
            .connect()
            .await
            .context("Failed to establish connection with Channel")?
    } else if let Some(path) = cli.gateway_endpoint.strip_prefix("unix://") {
        let path = path.to_owned();
        tonic::transport::Endpoint::try_from("http://[::]:50051")?
            .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
                let path = path.clone();
                async move {
                    Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(
                        tokio::net::UnixStream::connect(&path).await?,
                    ))
                }
            }))
            .await
            .context("Failed to establish unix socket connection with Channel")?
    } else if cli.gateway_endpoint.starts_with("https://") {
        let uri: url::Url = cli
            .gateway_endpoint
            .parse()
            .context("Failed to parse gateway_endpoint")?;

        let tls = tonic::transport::ClientTlsConfig::new()
            .domain_name(
                uri.domain()
                    .ok_or(anyhow::anyhow!("No domain_name found for gateway_endpoint"))?,
            )
            .with_enabled_roots();
        Channel::builder(cli.gateway_endpoint.parse()?)
            .http2_keep_alive_interval(HTTP2_KEEPALIVE_INTERVAL)
            .keep_alive_timeout(HTTP2_KEEPALIVE_TIMEOUT)
            .keep_alive_while_idle(true)
            .tls_config(tls)
            .context("Failed to attach tls config")?
            .connect()
            .await
            .context("Failed to establish connection with Channel")?
    } else {
        Channel::builder(cli.gateway_endpoint.parse()?)
            .http2_keep_alive_interval(HTTP2_KEEPALIVE_INTERVAL)
            .keep_alive_timeout(HTTP2_KEEPALIVE_TIMEOUT)
            .keep_alive_while_idle(true)
            .connect()
            .await
            .context("Failed to establish connection with Channel")?
    };

    let interceptor = if let Some(t) = cli.get_authorization_token().await? {
        BuilderInterceptor::Token {
            token: format!("Bearer {t}").parse()?,
        }
    } else {
        BuilderInterceptor::Noop
    };

    Ok(RunnerServiceClient::with_interceptor(channel, interceptor)
        .send_compressed(tonic::codec::CompressionEncoding::Zstd)
        .accept_compressed(tonic::codec::CompressionEncoding::Zstd)
        .max_decoding_message_size(50 * 1024 * 1024)
        .max_encoding_message_size(50 * 1024 * 1024))
}

#[tracing::instrument(skip(state), err)]
async fn handle_request(
    state: Arc<crate::state::State>,
    request: runner_request::Message,
) -> anyhow::Result<()> {
    match request {
        runner_request::Message::Join(m) => {
            state
                .max_concurrent_downloads
                .store(m.max_concurrent_downloads, Ordering::Relaxed);
        }
        runner_request::Message::ConfigUpdate(m) => {
            state
                .max_concurrent_downloads
                .store(m.max_concurrent_downloads, Ordering::Relaxed);
        }
        runner_request::Message::Ping(_) => (),
        runner_request::Message::Build(m) => {
            state.schedule_build(m)?;
        }
        runner_request::Message::Abort(m) => {
            state.abort_build(&m)?;
        }
    }
    Ok(())
}

#[tracing::instrument(skip(state), err)]
async fn check_version_compatibility(state: Arc<crate::state::State>) -> anyhow::Result<()> {
    let mut client = state.client.clone();

    let response = client
        .check_version(Request::new(VersionCheckRequest {
            version: crate::state::PROTO_API_VERSION.to_string(),
            machine_id: state.id.to_string(),
            hostname: state.hostname.clone(),
            store_dir: nix_utils::get_store_dir().to_string(),
        }))
        .await?;
    let response = response.into_inner();

    if !response.compatible {
        return Err(anyhow::anyhow!(
            "API version mismatch: client has {}, server has {}",
            crate::state::PROTO_API_VERSION,
            response.server_version,
        ));
    }

    tracing::info!(
        "Version check passed: client={}, server={}",
        crate::state::PROTO_API_VERSION,
        response.server_version
    );
    Ok(())
}

#[tracing::instrument(skip(state), err)]
pub async fn start_bidirectional_stream(state: Arc<crate::state::State>) -> anyhow::Result<()> {
    use tokio_stream::StreamExt as _;

    check_version_compatibility(state.clone()).await?;

    let join_msg = state.get_join_message().await?;
    let state2 = state.clone();

    // Subscribe a fresh receiver for this stream connection.  Using a
    // broadcast channel means each reconnection gets its own receiver
    // without needing to recreate the sender or the State.
    let mut slot_freed_rx = state.slot_freed_tx.subscribe();

    // The outbound stream merges periodic ping messages with SlotFreed
    // notifications from build tasks.  Using `tokio::select!` inside an
    // `async_stream` lets us yield whichever is ready first while keeping
    // a single ordered stream for the gRPC tunnel.
    let ping_stream = async_stream::stream! {
        yield BuilderRequest {
            message: Some(builder_request::Message::Join(join_msg))
        };

        let mut interval = tokio::time::interval(Duration::from_secs(state.config.ping_interval));
        loop {
            tokio::select! {
                _ = interval.tick() => {
                    let ping = match state.get_ping_message() {
                        Ok(v) => builder_request::Message::Ping(v),
                        Err(e) => {
                            tracing::error!("Failed to construct ping message: {e}");
                            continue
                        },
                    };
                    tracing::debug!("sending ping: {ping:?}");

                    yield BuilderRequest {
                        message: Some(ping)
                    };
                }
                msg = slot_freed_rx.recv() => {
                    match msg {
                        Ok(msg) => {
                            tracing::info!(
                                "sending slot_freed: build_id={} machine_id={}",
                                msg.build_id, msg.machine_id
                            );
                            yield BuilderRequest {
                                message: Some(builder_request::Message::SlotFreed(msg))
                            };
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("slot_freed receiver lagged by {n} messages");
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            // Sender dropped -- no more SlotFreed messages,
                            // but keep pinging.
                        }
                    }
                }
            }
        }
    };

    let response = state2
        .client
        .clone()
        .open_tunnel(Request::new(ping_stream))
        .await;

    let mut stream = match response {
        Ok(response) => response.into_inner(),
        Err(e) => {
            let error_str = e.to_string();
            if error_str.contains("API version mismatch") {
                return Err(anyhow::anyhow!("API version mismatch: {error_str}"));
            }
            return Err(e.into());
        }
    };

    let mut consecutive_failure_count = 0;
    loop {
        match tokio::time::timeout(STREAM_RECV_TIMEOUT, stream.next()).await {
            Ok(Some(item)) => match item.map(|v| v.message) {
                Ok(Some(v)) => {
                    consecutive_failure_count = 0;
                    if let Err(err) = handle_request(state2.clone(), v).await {
                        tracing::error!("Failed to correctly handle request: {err}");
                    }
                }
                Ok(None) => {
                    consecutive_failure_count = 0;
                }
                Err(e) => {
                    consecutive_failure_count += 1;
                    tracing::error!("stream message delivery failed: {e}");
                    if consecutive_failure_count == 10 {
                        return Err(anyhow::anyhow!(
                            "Failed to communicate {consecutive_failure_count} times over the channel. \
                            Terminating the application."
                        ));
                    }
                }
            },
            Ok(None) => {
                // Stream ended cleanly
                tracing::info!("gRPC stream ended");
                break;
            }
            Err(_) => {
                // No message received within STREAM_RECV_TIMEOUT — connection is likely dead.
                return Err(anyhow::anyhow!(
                    "No message from queue runner in {}s — assuming dead connection",
                    STREAM_RECV_TIMEOUT.as_secs()
                ));
            }
        }
    }
    Ok(())
}
