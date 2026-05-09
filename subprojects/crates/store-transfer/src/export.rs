//! Shared logic for exporting store paths as an `AddToStoreRequest` stream.

use harmonia_store_path::StorePath;
use harmonia_store_path_info::UnkeyedValidPathInfo;

/// Export store paths as `AddToStoreRequest` messages over a gRPC channel.
///
/// Sends an [`AddToStoreHeader`] containing all path infos first,
/// then zstd-compressed `nar_chunk` messages with all NARs
/// concatenated in the same order. One continuous zstd stream.
///
/// The `infos` map must contain an entry for every path. Paths
/// missing from the map are skipped.
pub async fn export(
    guard: &mut harmonia_store_remote::PooledConnectionGuard,
    paths: &[StorePath],
    infos: &hashbrown::HashMap<StorePath, UnkeyedValidPathInfo>,
    tx: &tokio::sync::mpsc::UnboundedSender<Result<hydra_proto::AddToStoreRequest, tonic::Status>>,
) -> Result<(), crate::Error> {
    use tokio::io::AsyncBufReadExt as _;

    // Send header with all path infos (uncompressed).
    let proto_infos: Vec<hydra_proto::ValidPathInfo> = paths
        .iter()
        .filter_map(|p| {
            infos.get(p).map(|info| hydra_proto::ValidPathInfo {
                path: Some(hydra_proto::ProtoStorePath::from(p.clone())),
                info: Some(hydra_proto::UnkeyedValidPathInfo::from(info)),
            })
        })
        .collect();

    if tx
        .send(Ok(hydra_proto::AddToStoreRequest {
            content: Some(hydra_proto::add_to_store_request::Content::Header(
                hydra_proto::AddToStoreHeader {
                    path_infos: proto_infos,
                },
            )),
        }))
        .is_err()
    {
        return Ok(());
    }

    // Stream all NARs as one continuous zstd-compressed stream.
    // We use a duplex pipe: write compressed data to one end,
    // spawn a task to read from the other and send as gRPC chunks.
    let (compressed_writer, compressed_reader) = tokio::io::duplex(crate::PIPE_BUFFER_SIZE);

    let tx_clone = tx.clone();
    let chunk_sender = tokio::spawn(async move {
        use tokio::io::AsyncReadExt as _;
        let mut reader = compressed_reader;
        let mut buf = vec![0u8; crate::COPY_BUFFER_SIZE];
        loop {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            if tx_clone
                .send(Ok(hydra_proto::AddToStoreRequest {
                    content: Some(hydra_proto::add_to_store_request::Content::NarChunk(
                        buf[..n].to_vec(),
                    )),
                }))
                .is_err()
            {
                break;
            }
        }
        Ok::<(), crate::Error>(())
    });

    // Write NARs through zstd encoder to the duplex pipe.
    let mut encoder = async_compression::tokio::write::ZstdEncoder::new(compressed_writer);

    for path in paths {
        let Some(info) = infos.get(path) else {
            continue;
        };

        let mut bytes_written: u64 = 0;
        use harmonia_protocol::types::DaemonStore;
        let mut nar_reader = guard.client().nar_from_path(path).await?;
        loop {
            let buf = nar_reader.fill_buf().await?;
            if buf.is_empty() {
                break;
            }
            use tokio::io::AsyncWriteExt as _;
            bytes_written += buf.len() as u64;
            encoder.write_all(buf).await?;
            let len = buf.len();
            nar_reader.consume(len);
        }

        // A mismatch here means the daemon and our recorded path info
        // disagree on the NAR contents.
        if bytes_written != info.nar_size {
            return Err(crate::ProtocolError::NarSizeMismatch {
                path: path.clone(),
                expected: info.nar_size,
                actual: bytes_written,
            }
            .into());
        }
    }

    use tokio::io::AsyncWriteExt as _;
    encoder.shutdown().await?;
    drop(encoder);

    chunk_sender.await??;

    Ok(())
}
