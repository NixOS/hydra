use harmonia_store_path::StorePath;
use tokio::io::BufReader;
use tokio_util::io::ReaderStream;

use hydra_proto::LogChunk;
use hydra_proto::ProtoStorePath;

pub(crate) type CompressionEncoder<R> = async_compression::tokio::bufread::ZstdEncoder<R>;
const DUPLEX_BUFFER_SIZE: usize = 256 * 1024;

/// Build a gRPC `LogChunk` stream from a channel of raw log bytes.
///
/// Log data received on `rx` is zstd-compressed and yielded as
/// `LogChunk` messages.  The first chunk carries the drv path so the
/// server knows which build the log belongs to.
pub(crate) fn compressed_log_stream(
    drv: &StorePath,
    rx: tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>,
) -> impl tokio_stream::Stream<Item = LogChunk> + use<> {
    let (raw_writer, raw_reader) = tokio::io::duplex(DUPLEX_BUFFER_SIZE);

    tokio::task::spawn(async move {
        use tokio::io::AsyncWriteExt as _;
        use tokio_stream::StreamExt as _;

        let mut rx = tokio_stream::wrappers::UnboundedReceiverStream::new(rx);
        let mut raw_writer = raw_writer;

        while let Some(chunk) = rx.next().await {
            if raw_writer.write_all(&chunk).await.is_err() {
                break;
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
                    drv: if first { first = false; Some(drv.clone()) } else { None },
                    data: bytes.into(),
                },
                Err(e) => {
                    // Zstd encoding of in-memory data should never
                    // fail. The only input is the duplex pipe reader
                    // which returns EOF when the writer is dropped.
                    panic!("Failed to compress log chunk: {e}");
                }
            }
        }
    }
}
