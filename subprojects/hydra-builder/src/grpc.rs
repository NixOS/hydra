use crate::error::BuilderError;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use std::time::Duration;

use tonic::{
    Request,
    service::interceptor::InterceptedService,
    transport::{Channel, Endpoint},
};

use backon::RetryableWithContext as _;
use harmonia_store_path::StorePath;
use hydra_proto::{
    BuildResultInfo, BuilderRequest, PresignedUploadComplete, VersionCheckRequest, builder_request,
    runner_request, runner_service_client::RunnerServiceClient,
};

const RETRY_MIN_DELAY: Duration = Duration::from_secs(3);
const RETRY_MAX_DELAY: Duration = Duration::from_secs(90);

fn retry_strategy() -> backon::ExponentialBuilder {
    backon::ExponentialBuilder::default()
        .with_jitter()
        .with_min_delay(RETRY_MIN_DELAY)
        .with_max_delay(RETRY_MAX_DELAY)
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

#[derive(Debug, Clone)]
pub struct BuilderClient(pub RunnerServiceClient<InterceptedService<Channel, BuilderInterceptor>>);

impl std::ops::Deref for BuilderClient {
    type Target = RunnerServiceClient<InterceptedService<Channel, BuilderInterceptor>>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for BuilderClient {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl BuilderClient {
    /// Retry a gRPC call across transient transport failures. The channel to
    /// the queue runner is long-lived and proxied through nginx, which
    /// periodically recycles HTTP/2 connections; a recycle racing an in-flight
    /// request surfaces as a transport cancellation, so every RPC retries on a
    /// fresh connection instead of failing the build.
    async fn call_with_retry<T, F, Fut>(&self, what: &'static str, f: F) -> Result<T, tonic::Status>
    where
        F: FnMut(Self) -> Fut,
        Fut: Future<Output = (Self, Result<T, tonic::Status>)>,
    {
        f.retry(retry_strategy())
            .sleep(tokio::time::sleep)
            .context(self.clone())
            .notify(move |err: &tonic::Status, dur: Duration| {
                tracing::warn!("{what} failed: err={err}, retrying in={dur:?}");
            })
            .await
            .1
    }

    pub async fn complete_build(&self, body: BuildResultInfo) -> Result<(), tonic::Status> {
        self.call_with_retry("complete_build", |mut client: Self| {
            let body = body.clone();
            async move {
                let res = client.0.complete_build(body).await.map(|_| ());
                (client, res)
            }
        })
        .await
    }

    pub async fn notify_presigned_upload_complete(
        &self,
        msg: PresignedUploadComplete,
    ) -> Result<(), tonic::Status> {
        self.call_with_retry("notify_presigned_upload_complete", |mut client: Self| {
            let msg = msg.clone();
            async move {
                let res = client
                    .0
                    .notify_presigned_upload_complete(msg)
                    .await
                    .map(|_| ());
                (client, res)
            }
        })
        .await
    }

    #[tracing::instrument(skip(self, store_paths), err)]
    pub async fn request_presigned_urls(
        &self,
        build_id: &str,
        machine_id: &str,
        store_paths: Vec<(
            StorePath,
            harmonia_store_path_info::NarHash,
            u64,
            Vec<String>,
        )>,
    ) -> Result<Vec<hydra_proto::PresignedNarResponse>, BuilderError> {
        use hydra_proto::{PresignedNarRequest, PresignedUrlRequest};

        let request = store_paths
            .into_iter()
            .map(|(path, nar_hash, nar_size, build_ids)| {
                let hash: harmonia_utils_hash::Hash = nar_hash.into();
                PresignedNarRequest {
                    store_path: path.to_string(),
                    nar_hash: Some((&hash).into()),
                    debug_info_build_ids: build_ids,
                    nar_size,
                }
            })
            .collect::<Vec<_>>();

        let req = PresignedUrlRequest {
            build_id: build_id.to_owned(),
            machine_id: machine_id.to_owned(),
            request,
        };

        let response = self
            .call_with_retry("request_presigned_url", |mut client: Self| {
                let req = req.clone();
                async move {
                    let res = client.0.request_presigned_url(req).await;
                    (client, res)
                }
            })
            .await
            .map_err(BuilderError::PresignedUrls)?;

        Ok(response.into_inner().inner)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn request_multipart_parts(
        &self,
        req: hydra_proto::MultipartPartsRequest,
    ) -> Result<Vec<hydra_proto::MultipartPart>, BuilderError> {
        let response = self
            .call_with_retry("request_multipart_parts", |mut client: Self| {
                let req = req.clone();
                async move {
                    let res = client.0.request_multipart_parts(req).await;
                    (client, res)
                }
            })
            .await
            .map_err(BuilderError::PresignedUrls)?;

        Ok(response.into_inner().parts)
    }
}

/// Apply HTTP/2 keepalive pings to the channel. The builder holds a single
/// long-lived channel and the queue runner sits behind nginx, which recycles
/// idle HTTP/2 connections; keepalive pings keep the connection healthy and let
/// tonic notice a dropped connection promptly instead of stalling.
fn configure_endpoint(endpoint: Endpoint) -> Endpoint {
    endpoint
        .http2_keep_alive_interval(Duration::from_secs(20))
        .keep_alive_timeout(Duration::from_secs(20))
        .keep_alive_while_idle(true)
}

#[tracing::instrument(err)]
pub async fn init_client(cli: &crate::config::Cli) -> Result<BuilderClient, BuilderError> {
    if !cli.mtls_configured_correctly() {
        tracing::error!(
            "mtls configured inproperly, please pass all options: \
            server_root_ca_cert_path, client_cert_path, client_key_path and domain_name!"
        );
        return Err(BuilderError::Configuration(
            crate::config::ConfigError::MtlsIncomplete,
        ));
    }

    tracing::info!("connecting to {}", cli.gateway_endpoint);
    let channel = if cli.mtls_enabled() {
        tracing::info!("mtls is enabled");
        let (server_root_ca_cert, client_identity, domain_name) =
            cli.get_mtls().await.map_err(BuilderError::Configuration)?;
        let tls = tonic::transport::ClientTlsConfig::new()
            .domain_name(domain_name)
            .ca_certificate(server_root_ca_cert)
            .identity(client_identity);

        configure_endpoint(
            Channel::builder(
                cli.gateway_endpoint
                    .parse()
                    .map_err(BuilderError::GatewayEndpoint)?,
            )
            .tls_config(tls)
            .map_err(BuilderError::TlsConfig)?,
        )
        .connect()
        .await
        .map_err(BuilderError::Connection)?
    } else if let Some(path) = cli.gateway_endpoint.strip_prefix("unix://") {
        let path = path.to_owned();
        configure_endpoint(Endpoint::from_static("http://[::]:50051"))
            .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
                let path = path.clone();
                async move {
                    Ok::<_, std::io::Error>(hyper_util::rt::TokioIo::new(
                        tokio::net::UnixStream::connect(&path).await?,
                    ))
                }
            }))
            .await
            .map_err(BuilderError::Connection)?
    } else if cli.gateway_endpoint.starts_with("https://") {
        let uri: http::uri::Uri = cli
            .gateway_endpoint
            .parse()
            .map_err(BuilderError::GatewayEndpoint)?;

        let tls = tonic::transport::ClientTlsConfig::new()
            .domain_name(uri.host().ok_or(BuilderError::GatewayMissingHost)?)
            .with_enabled_roots();
        configure_endpoint(
            Channel::builder(
                cli.gateway_endpoint
                    .parse()
                    .map_err(BuilderError::GatewayEndpoint)?,
            )
            .tls_config(tls)
            .map_err(BuilderError::TlsConfig)?,
        )
        .connect()
        .await
        .map_err(BuilderError::Connection)?
    } else {
        configure_endpoint(Channel::builder(
            cli.gateway_endpoint
                .parse()
                .map_err(BuilderError::GatewayEndpoint)?,
        ))
        .connect()
        .await
        .map_err(BuilderError::Connection)?
    };

    let interceptor = if let Some(t) = cli.get_authorization_token().await? {
        BuilderInterceptor::Token {
            token: format!("Bearer {t}")
                .parse()
                .map_err(BuilderError::AuthToken)?,
        }
    } else {
        BuilderInterceptor::Noop
    };

    Ok(BuilderClient(
        RunnerServiceClient::with_interceptor(channel, interceptor)
            .max_decoding_message_size(50 * 1024 * 1024)
            .max_encoding_message_size(50 * 1024 * 1024),
    ))
}

#[tracing::instrument(skip(state), err)]
async fn handle_request(
    state: Arc<crate::state::State>,
    request: runner_request::Message,
) -> Result<(), BuilderError> {
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
            state
                .schedule_build(m)
                .map_err(BuilderError::HandlingRequest)?;
        }
        runner_request::Message::Abort(m) => {
            state
                .abort_build(&m)
                .map_err(BuilderError::HandlingRequest)?;
        }
    }
    Ok(())
}

#[tracing::instrument(skip(state), err)]
async fn check_version_compatibility(state: Arc<crate::state::State>) -> Result<(), BuilderError> {
    let mut client = state.client.clone();

    let response = client
        .check_version(Request::new(VersionCheckRequest {
            version: hydra_proto::PROTO_API_VERSION.to_string(),
            machine_id: state.id.to_string(),
            hostname: state.hostname.clone(),
            store_dir: state.config.store_dir.to_string(),
        }))
        .await
        .map_err(BuilderError::CallingService)?;
    let response = response.into_inner();

    if !response.compatible {
        return Err(BuilderError::VersionIncompatible(response.server_version));
    }

    tracing::info!(
        "Version check passed: client={}, server={}",
        hydra_proto::PROTO_API_VERSION,
        response.server_version
    );
    Ok(())
}

#[tracing::instrument(skip(state), err)]
pub async fn start_bidirectional_stream(
    state: Arc<crate::state::State>,
) -> Result<(), BuilderError> {
    use tokio_stream::StreamExt as _;

    check_version_compatibility(state.clone()).await?;

    let join_msg = state
        .get_join_message()
        .await
        .map_err(BuilderError::ReadingSystemInfo)?;
    let state2 = state.clone();
    let ping_stream = async_stream::stream! {
        yield BuilderRequest {
            message: Some(builder_request::Message::Join(join_msg))
        };

        let mut interval = tokio::time::interval(Duration::from_secs(state.config.ping_interval));
        loop {
            interval.tick().await;

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
    };

    let response = state2
        .client
        .clone()
        .open_tunnel(Request::new(ping_stream))
        .await;

    let mut stream = match response {
        Ok(response) => response.into_inner(),
        Err(e) => {
            return Err(BuilderError::CallingService(e));
        }
    };

    let mut consecutive_failure_count = 0;
    while let Some(item) = stream.next().await {
        match item.map(|v| v.message) {
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
                    return Err(BuilderError::RepeatedFailure(consecutive_failure_count));
                }
            }
        }
    }
    Ok(())
}
