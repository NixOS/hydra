mod error;
pub mod export;
pub mod import;

pub use error::{Error, ProtocolError};

/// Capacity of the duplex pipe bridging the zstd codec and the gRPC
/// chunk stream.
const PIPE_BUFFER_SIZE: usize = 256 * 1024;

/// Size of the scratch buffer used to copy bytes between the duplex pipe
/// and the NAR/chunk streams.
const COPY_BUFFER_SIZE: usize = 64 * 1024;
