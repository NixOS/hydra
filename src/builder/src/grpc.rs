use std::sync::Arc;
use std::sync::atomic::Ordering;

use anyhow::Context as _;
use tonic::{Request, service::interceptor::InterceptedService, transport::Channel};

use runner_v1::{
    BuilderRequest, VersionCheckRequest, builder_request, runner_request,
    runner_service_client::RunnerServiceClient,
};

pub mod runner_v1 {
    // We need to allow pedantic here because of generated code
    #![allow(clippy::pedantic)]

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
    fn call(&mut self, request: tonic::Request<()>) -> Result<tonic::Request<()>, tonic::Status> {
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
                store_path: path.base_name().to_owned(),
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

        tonic::transport::Channel::builder(cli.gateway_endpoint.parse()?)
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
    } else {
        tonic::transport::Channel::builder(cli.gateway_endpoint.parse()?)
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
    let ping_stream = async_stream::stream! {
        yield BuilderRequest {
            message: Some(builder_request::Message::Join(join_msg))
        };

        let mut interval = tokio::time::interval(std::time::Duration::from_secs(state.config.ping_interval));
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
            let error_str = e.to_string();
            if error_str.contains("API version mismatch") {
                return Err(anyhow::anyhow!("API version mismatch: {error_str}"));
            }
            return Err(e.into());
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
                    return Err(anyhow::anyhow!(
                        "Failed to communicate {consecutive_failure_count} times over the channel. \
                        Terminating the application."
                    ));
                }
            }
        }
    }
    Ok(())
}
