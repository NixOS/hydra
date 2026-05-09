/// Protocol-level errors in the `AddToStoreRequest` stream.
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("empty AddToStoreRequest stream")]
    EmptyStream,

    #[error("expected AddToStoreHeader as first message")]
    MissingHeader,

    #[error("PathInfo missing required field: {0}")]
    MissingGrpcField(&'static str),

    #[error("invalid path info: {0}")]
    InvalidPathInfo(#[from] hydra_proto::NarInfoConvertError),

    #[error("unexpected end of NAR stream for {path}, {remaining} bytes remaining")]
    TruncatedNar {
        path: harmonia_store_path::StorePath,
        remaining: u64,
    },

    #[error("NAR size mismatch for {path}: wrote {actual} bytes, expected {expected}")]
    NarSizeMismatch {
        path: harmonia_store_path::StorePath,
        expected: u64,
        actual: u64,
    },
}

/// Errors during store path import/export over gRPC.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The underlying daemon store operation failed.
    #[error(transparent)]
    Store(#[from] harmonia_protocol::types::DaemonError),

    /// gRPC transport error.
    #[error("gRPC error: {0}")]
    Grpc(#[from] tonic::Status),

    /// IO error during NAR streaming.
    #[error(transparent)]
    Io(#[from] std::io::Error),

    /// The gRPC protocol was violated.
    #[error(transparent)]
    Protocol(#[from] ProtocolError),

    /// A spawned task panicked or was cancelled.
    #[error("task join error: {0}")]
    Join(#[from] tokio::task::JoinError),
}
