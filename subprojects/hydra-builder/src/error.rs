#[derive(Debug, thiserror::Error)]
pub enum BuilderError {
    #[error("Requesting presigned URLs")]
    PresignedUrls(#[source] tonic::Status),

    #[error("Parsing configuration")]
    Configuration(#[from] crate::config::ConfigError),

    #[error("Parsing gateway endpoint")]
    GatewayEndpoint(#[source] http::uri::InvalidUri),

    #[error("Gateway API missing host")]
    GatewayMissingHost,

    #[error("Connecting to channel")]
    Connection(#[source] tonic::transport::Error),

    #[error("Attaching TLS Configuration")]
    TlsConfig(#[source] tonic::transport::Error),

    #[error("Incorrectly formatted authorisation token")]
    AuthToken(#[source] tonic::metadata::errors::InvalidMetadataValue),

    #[error("Calling service")]
    CallingService(#[source] tonic::Status),

    #[error("API version mismatch: client has {ver}, server has {0}", ver=hydra_proto::PROTO_API_VERSION)]
    VersionIncompatible(String),

    #[error("Reading system information")]
    ReadingSystemInfo(#[source] anyhow::Error),

    #[error("Failed to communicate {0} times over the channel. Terminating the application.")]
    RepeatedFailure(u32),

    #[error("While handling request")]
    HandlingRequest(#[source] anyhow::Error),

    #[error("Task failed")]
    Task(#[from] tokio::task::JoinError),
}
