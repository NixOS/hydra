//! Shared logic for importing store paths from an `AddToStoreRequest` stream.

/// Import store paths from a gRPC `stream AddToStoreRequest`.
///
/// The first message must be an [`AddToStoreHeader`] containing all
/// [`ValidPathInfo`]s. Subsequent messages must be zstd-compressed
/// `nar_chunk` bytes containing the NARs for all paths concatenated
/// in the same (dependency) order as the header.
pub async fn import(
    store: &impl nix_utils::BaseStore,
    mut stream: tonic::Streaming<hydra_proto::AddToStoreRequest>,
) -> Result<Vec<harmonia_store_core::store_path::StorePath>, nix_utils::Error> {
    use futures::StreamExt as _;
    use nix_utils::Error;

    // First message must be the header.
    let first = stream
        .next()
        .await
        .ok_or_else(|| anyhow::anyhow!("empty AddToStoreRequest stream"))?
        .map_err(|e| Error::Anyhow(e.into()))?;

    let header = match first.content {
        Some(hydra_proto::add_to_store_request::Content::Header(h)) => h,
        _ => return Err(anyhow::anyhow!("expected AddToStoreHeader as first message").into()),
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
        .collect::<anyhow::Result<_>>()
        .map_err(Error::Anyhow)?;

    let paths: Vec<_> = path_infos.iter().map(|pi| pi.path.clone()).collect();

    if path_infos.is_empty() {
        return Ok(paths);
    }

    // Pipe compressed NAR data through a zstd decoder into
    // add_multiple_to_store. Spawn the stream reader so it can write
    // concurrently while add_multiple_to_store reads from the other end.
    let (mut compressed_writer, compressed_reader) = tokio::io::duplex(256 * 1024);
    let decoder = async_compression::tokio::bufread::ZstdDecoder::new(tokio::io::BufReader::new(
        compressed_reader,
    ));
    let nar_stream = tokio_util::io::ReaderStream::new(decoder);

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

    store
        .add_multiple_to_store(&path_infos, nar_stream, false)
        .await?;

    writer_handle
        .await
        .map_err(|e| Error::Anyhow(e.into()))?
        .map_err(Error::Anyhow)?;

    Ok(paths)
}
