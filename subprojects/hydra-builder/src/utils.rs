use tokio::io::BufReader;
use tokio_stream::wrappers::LinesStream;
use tokio_util::io::ReaderStream;

use crate::grpc::runner_v1::LogChunk;
use shared::proto::ProtoStorePath;

pub(crate) type CompressionEncoder<R> = async_compression::tokio::bufread::ZstdEncoder<R>;
pub(crate) type CompressionDecoder<R> = async_compression::tokio::bufread::ZstdDecoder<R>;
pub(crate) const DUPLEX_BUFFER_SIZE: usize = 256 * 1024;

pub(crate) fn compressed_log_stream(
    drv: &nix_utils::StorePath,
    log_output: LinesStream<BufReader<tokio::process::ChildStderr>>,
) -> impl tokio_stream::Stream<Item = LogChunk> + use<> {
    let (raw_writer, raw_reader) = tokio::io::duplex(DUPLEX_BUFFER_SIZE);

    tokio::task::spawn(async move {
        use tokio::io::AsyncWriteExt as _;
        use tokio_stream::StreamExt as _;

        let mut log_output = log_output;
        let mut raw_writer = raw_writer;

        while let Some(chunk) = log_output.next().await {
            match chunk {
                Ok(line) => {
                    let data = format!("{line}\n");
                    if raw_writer.write_all(data.as_bytes()).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    tracing::error!("Failed to read log chunk: {e}");
                    break;
                }
            }
        }
    });

    let encoder = CompressionEncoder::new(BufReader::new(raw_reader));
    let mut encoded_stream = ReaderStream::new(encoder);
    let drv = ProtoStorePath::from(drv.clone());

    async_stream::stream! {
        use tokio_stream::StreamExt as _;
        let mut first = true;
        while let Some(chunk) = encoded_stream.next().await {
            match chunk {
                Ok(bytes) => yield LogChunk {
                    // Only the first chunk needs the drv; server reads it once
                    drv: if first { first = false; Some(drv.clone()) } else {None},
                    data: bytes.into(),
                },
                Err(e) => {
                    tracing::error!("Failed to compress log chunk: {e}");
                    break;
                }
            }
        }
    }
}
