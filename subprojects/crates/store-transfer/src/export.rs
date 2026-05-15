//! Shared logic for exporting store paths as an `AddToStoreRequest` stream.

use harmonia_store_core::store_path::StorePath;
use harmonia_store_path_info::UnkeyedValidPathInfo;
use nix_utils::BaseStore;

/// Export store paths as `AddToStoreRequest` messages over a gRPC channel.
///
/// Sends an [`AddToStoreHeader`] containing all path infos first,
/// then zstd-compressed `nar_chunk` messages with all NARs
/// concatenated in the same order. One continuous zstd stream.
///
/// The `infos` map must contain an entry for every path. Paths
/// missing from the map are skipped.
///
/// This function is synchronous (designed to run inside
/// `spawn_blocking`).
pub fn export(
    store: &impl BaseStore,
    paths: &[StorePath],
    infos: &hashbrown::HashMap<StorePath, UnkeyedValidPathInfo>,
    tx: &tokio::sync::mpsc::UnboundedSender<Result<hydra_proto::AddToStoreRequest, tonic::Status>>,
) {
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
        return;
    }

    // Stream all NARs as one continuous zstd-compressed stream.
    let mut encoder =
        zstd::stream::Encoder::new(NarChunkWriter(tx), 3).expect("failed to create zstd encoder");

    for path in paths {
        let Some(info) = infos.get(path) else {
            continue;
        };

        let mut bytes_written: u64 = 0;
        let enc = &mut encoder;
        let written = &mut bytes_written;
        let closure = |data: &[u8]| -> bool {
            use std::io::Write;
            *written += data.len() as u64;
            enc.write_all(data).is_ok()
        };
        if store.nar_from_path(path, closure).is_err() {
            break;
        }

        assert_eq!(
            bytes_written, info.nar_size,
            "NAR size mismatch for {path}: wrote {bytes_written} bytes, expected {}",
            info.nar_size
        );
    }

    let _ = encoder.finish();
}

/// Adapter: writes bytes as `nar_chunk` messages to a gRPC channel.
struct NarChunkWriter<'a>(
    &'a tokio::sync::mpsc::UnboundedSender<Result<hydra_proto::AddToStoreRequest, tonic::Status>>,
);

impl std::io::Write for NarChunkWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self
            .0
            .send(Ok(hydra_proto::AddToStoreRequest {
                content: Some(hydra_proto::add_to_store_request::Content::NarChunk(
                    buf.to_vec(),
                )),
            }))
            .is_ok()
        {
            Ok(buf.len())
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "gRPC channel closed",
            ))
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
