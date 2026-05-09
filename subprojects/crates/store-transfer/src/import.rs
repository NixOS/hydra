//! Shared logic for importing store paths from an `AddToStoreRequest` stream.

/// Import store paths from a gRPC `stream AddToStoreRequest`.
///
/// The first message must be an [`AddToStoreHeader`] containing all
/// [`ValidPathInfo`]s (including NAR sizes). Then zstd-compressed
/// `nar_chunk` bytes with all NARs concatenated in header order.
///
/// Rust splits the decompressed stream by counting `nar_size` bytes
/// per path and feeds each slice into `add_to_store_nar`.
pub async fn import(
    guard: &mut harmonia_store_remote::PooledConnectionGuard,
    mut stream: tonic::Streaming<hydra_proto::AddToStoreRequest>,
) -> anyhow::Result<Vec<harmonia_store_path::StorePath>> {
    use futures::StreamExt as _;
    use harmonia_protocol::types::DaemonStore;

    // First message must be the header.
    let first = stream
        .next()
        .await
        .ok_or_else(|| anyhow::anyhow!("empty AddToStoreRequest stream"))?
        .map_err(|e| anyhow::anyhow!("stream error: {e}"))?;

    let header = match first.content {
        Some(hydra_proto::add_to_store_request::Content::Header(h)) => h,
        _ => {
            return Err(anyhow::anyhow!(
                "expected AddToStoreHeader as first message"
            ));
        }
    };

    let path_infos: Vec<harmonia_store_path_info::ValidPathInfo> = header
        .path_infos
        .into_iter()
        .map(|pi| {
            let path = pi
                .path
                .ok_or_else(|| anyhow::anyhow!("missing path in PathInfo"))?
                .0;
            let info = pi
                .info
                .ok_or_else(|| anyhow::anyhow!("missing info in PathInfo"))?
                .try_into()
                .map_err(|e| anyhow::anyhow!("invalid path info: {e}"))?;
            Ok(harmonia_store_path_info::ValidPathInfo { path, info })
        })
        .collect::<anyhow::Result<_>>()?;

    let paths: Vec<_> = path_infos.iter().map(|pi| pi.path.clone()).collect();

    if path_infos.is_empty() {
        return Ok(paths);
    }

    // Pipe compressed gRPC chunks through a zstd decoder. A spawned
    // task writes the compressed data; we read decompressed bytes
    // from the other end.
    let (mut compressed_writer, compressed_reader) = tokio::io::duplex(256 * 1024);

    let writer_handle = tokio::spawn(async move {
        while let Some(msg) = stream.next().await {
            let msg = msg?;
            if let Some(hydra_proto::add_to_store_request::Content::NarChunk(chunk)) = msg.content {
                use tokio::io::AsyncWriteExt as _;
                compressed_writer.write_all(&chunk).await?;
            }
        }
        drop(compressed_writer);
        Ok::<(), anyhow::Error>(())
    });

    let mut decoder = async_compression::tokio::bufread::ZstdDecoder::new(
        tokio::io::BufReader::new(compressed_reader),
    );

    // Import each path by reading exactly nar_size decompressed bytes
    // into a per-path duplex pipe feeding add_to_store_nar.
    for vpi in &path_infos {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

        let (mut nar_writer, nar_reader) = tokio::io::duplex(256 * 1024);
        let mut nar_buf_reader = tokio::io::BufReader::new(nar_reader);

        let copy_fut = async {
            let mut remaining = vpi.info.nar_size;
            let mut buf = vec![0u8; 64 * 1024];
            while remaining > 0 {
                let to_read = buf.len().min(remaining as usize);
                let n = decoder.read(&mut buf[..to_read]).await?;
                if n == 0 {
                    return Err(anyhow::anyhow!(
                        "unexpected end of NAR stream for {}, {remaining} bytes remaining",
                        vpi.path
                    ));
                }
                nar_writer.write_all(&buf[..n]).await?;
                remaining -= n as u64;
            }
            drop(nar_writer);
            Ok::<(), anyhow::Error>(())
        };

        let store_fut = guard
            .client()
            .add_to_store_nar(vpi, &mut nar_buf_reader, false, true);

        let (copy_result, store_result) = futures::future::join(copy_fut, store_fut).await;
        copy_result?;
        store_result?;
    }

    writer_handle.await??;

    Ok(paths)
}
