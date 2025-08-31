use std::sync::atomic::{AtomicU64, Ordering};

use backon::Retryable;

use bytes::Bytes;
use nix_utils::{BaseStore as _, LocalStore};

use tokio_util::io::StreamReader;

use crate::{CacheError, Compression, streaming_hash::HashingReader};

const RETRY_MIN_DELAY_SECS: u64 = 1;
const RETRY_MAX_DELAY_SECS: u64 = 30;
const RETRY_MAX_ATTEMPTS: usize = 3;

#[derive(Debug, Clone)]
pub struct PresignedUpload {
    pub path: String,
    pub url: String,
    pub compression: Compression,
    pub compression_level: async_compression::Level,
}

impl PresignedUpload {
    #[must_use]
    pub fn new(
        path: String,
        url: String,
        compression: Compression,
        compression_level: i32,
    ) -> Self {
        Self {
            path,
            url,
            compression,
            compression_level: match compression_level {
                1 => async_compression::Level::Fastest,
                l if (2..=8).contains(&l) => async_compression::Level::Precise(l),
                9 => async_compression::Level::Best,
                _ => async_compression::Level::Default,
            },
        }
    }

    #[must_use]
    pub const fn get_compression_level_as_i32(&self) -> i32 {
        match self.compression_level {
            async_compression::Level::Fastest => 1,
            async_compression::Level::Precise(n) => n,
            async_compression::Level::Best => 9,
            async_compression::Level::Default | _ => 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PresignedUploadResponse {
    pub nar_url: String,
    pub nar_upload: PresignedUpload,
    pub ls_upload: Option<PresignedUpload>,
    pub debug_info_upload: Vec<PresignedUpload>,
}

#[derive(Debug, Default)]
pub(crate) struct AtomicPresignedUploadMetrics {
    pub put: AtomicU64,
    pub put_bytes: AtomicU64,
    pub put_time_ms: AtomicU64,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct PresignedUploadMetrics {
    pub put: u64,
    pub put_bytes: u64,
    pub put_time_ms: u64,
}

#[derive(Debug, Clone)]
pub struct PresignedUploadResult {
    pub file_hash: String,
    pub file_size: u64,
}

#[derive(Debug, Clone)]
pub struct PresignedUploadClient {
    client: reqwest::Client,
    metrics: std::sync::Arc<AtomicPresignedUploadMetrics>,
}

impl PresignedUploadClient {
    #[must_use]
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::new(),
            metrics: std::sync::Arc::new(AtomicPresignedUploadMetrics::default()),
        }
    }

    #[must_use]
    pub fn metrics(&self) -> PresignedUploadMetrics {
        PresignedUploadMetrics {
            put: self.metrics.put.load(Ordering::Relaxed),
            put_bytes: self.metrics.put_bytes.load(Ordering::Relaxed),
            put_time_ms: self.metrics.put_time_ms.load(Ordering::Relaxed),
        }
    }

    #[tracing::instrument(skip(self, store, narinfo, req), err)]
    pub async fn process_presigned_request(
        &self,
        store: &LocalStore,
        mut narinfo: crate::NarInfo,
        req: PresignedUploadResponse,
    ) -> Result<crate::NarInfo, CacheError> {
        narinfo.url = req.nar_url;
        narinfo.compression = req.nar_upload.compression;

        if let Some(ls_upload) = req.ls_upload {
            let _ = self
                .upload_ls(store, &narinfo.store_path, &ls_upload)
                .await?;
        }

        if !req.debug_info_upload.is_empty() {
            let debug_info_client = PresignedDebugInfoUpload {
                client: self.clone(),
                debug_info_urls: std::sync::Arc::new(req.debug_info_upload),
            };
            crate::debug_info::process_debug_info(
                &narinfo.url,
                store,
                &narinfo.store_path,
                debug_info_client.clone(),
            )
            .await?;
        }

        let upload_res = self
            .upload_nar(store, &narinfo.store_path, &req.nar_upload)
            .await?;
        narinfo.file_hash = Some(upload_res.file_hash);
        narinfo.file_size = Some(upload_res.file_size);

        Ok(narinfo)
    }

    #[tracing::instrument(skip(self, store, store_path), err)]
    async fn upload_nar(
        &self,
        store: &LocalStore,
        store_path: &nix_utils::StorePath,
        upload: &PresignedUpload,
    ) -> Result<PresignedUploadResult, CacheError> {
        let start = std::time::Instant::now();

        let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<Result<Bytes, std::io::Error>>();
        let (result_tx, result_rx) = tokio::sync::oneshot::channel::<Result<(), String>>();

        let closure = {
            let tx = tx.clone();
            move |data: &[u8]| {
                let data = Bytes::copy_from_slice(data);
                tx.send(Ok(data)).is_ok()
            }
        };

        tokio::task::spawn({
            let path = store_path.clone();
            let store = store.clone();
            async move {
                let result = store
                    .nar_from_path(&path, closure)
                    .map_err(|e| format!("NAR reading failed: {e}"));
                let _ = result_tx.send(result);
            }
        });

        drop(tx);
        let stream = StreamReader::new(tokio_stream::wrappers::UnboundedReceiverStream::new(rx));
        let compressor = upload
            .compression
            .get_compression_fn(upload.compression_level, false);
        let compressed_stream = compressor(stream);
        let (hashing_reader, _) = HashingReader::new(compressed_stream);

        let upload_result = self.upload_any(upload, hashing_reader, start, None).await;

        match result_rx.await {
            Ok(Ok(())) => upload_result,
            Ok(Err(e)) => Err(CacheError::UploadError {
                path: upload.path.clone(),
                reason: e,
            }),
            Err(_) => Err(CacheError::UploadError {
                path: upload.path.clone(),
                reason: "NAR reading task was cancelled or panicked".to_string(),
            }),
        }
    }

    #[tracing::instrument(skip(self, store, store_path), err)]
    async fn upload_ls(
        &self,
        store: &LocalStore,
        store_path: &nix_utils::StorePath,
        upload: &PresignedUpload,
    ) -> Result<PresignedUploadResult, CacheError> {
        let start = std::time::Instant::now();

        let ls = store.list_nar_deep(store_path).await?;
        let stream = Box::new(std::io::Cursor::new(Bytes::from(ls)));
        let compressor = upload
            .compression
            .get_compression_fn(upload.compression_level, false);
        let compressed_stream = compressor(stream);
        let (hashing_reader, _) = HashingReader::new(compressed_stream);

        self.upload_any(upload, hashing_reader, start, Some("application/json"))
            .await
    }

    #[tracing::instrument(skip(self, content), err)]
    async fn upload_json(
        &self,
        content: String,
        upload: &PresignedUpload,
    ) -> Result<PresignedUploadResult, CacheError> {
        let start = std::time::Instant::now();

        let stream = Box::new(std::io::Cursor::new(Bytes::from(content)));
        let compressor = upload
            .compression
            .get_compression_fn(upload.compression_level, false);
        let compressed_stream = compressor(stream);
        let (hashing_reader, _) = HashingReader::new(compressed_stream);

        self.upload_any(upload, hashing_reader, start, Some("application/json"))
            .await
    }

    #[tracing::instrument(skip(self, start, reader), err)]
    async fn upload_any(
        &self,
        upload: &PresignedUpload,
        mut reader: HashingReader<Box<dyn tokio::io::AsyncRead + Send + Unpin>>,
        start: std::time::Instant,
        content_type: Option<&str>,
    ) -> Result<PresignedUploadResult, CacheError> {
        use tokio::io::AsyncReadExt as _;

        let mut request = self.client.put(&upload.url);
        if let Some(content_type) = content_type {
            request = request.header("Content-Type", content_type);
        } else {
            request = request.header("Content-Type", upload.compression.content_type());
        }
        if !upload.compression.content_encoding().is_empty() {
            request = request.header("Content-Encoding", upload.compression.content_encoding());
        }

        // TODO: We need multipart signed urls to fix this!
        //       object_store currently doesnt have support for this.
        let mut buffer = Vec::new();
        reader.read_to_end(&mut buffer).await?;

        let _response = (|| async {
            Ok::<_, CacheError>(
                request
                    .try_clone()
                    .ok_or_else(|| CacheError::RequestCloneError)?
                    .body(buffer.clone())
                    .send()
                    .await?
                    .error_for_status()?,
            )
        })
        .retry(
            &backon::ExponentialBuilder::default()
                .with_min_delay(std::time::Duration::from_secs(RETRY_MIN_DELAY_SECS))
                .with_max_delay(std::time::Duration::from_secs(RETRY_MAX_DELAY_SECS))
                .with_max_times(RETRY_MAX_ATTEMPTS),
        )
        .await?;

        let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();

        let (file_hash, file_size) = reader.finalize()?;

        let file_hash = nix_utils::convert_hash(
            &format!("{file_hash:x}"),
            Some(nix_utils::HashAlgorithm::SHA256),
            nix_utils::HashFormat::Nix32,
        )
        .map_or_else(
            |_| format!("sha256:{file_hash:x}"),
            |converted_hash| format!("sha256:{converted_hash}"),
        );

        // Update metrics
        self.metrics
            .put_bytes
            .fetch_add(file_size as u64, Ordering::Relaxed);
        self.metrics
            .put_time_ms
            .fetch_add(elapsed, Ordering::Relaxed);
        self.metrics.put.fetch_add(1, Ordering::Relaxed);

        Ok(PresignedUploadResult {
            file_hash,
            file_size: file_size as u64,
        })
    }
}

impl Default for PresignedUploadClient {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone)]
struct PresignedDebugInfoUpload {
    client: PresignedUploadClient,
    debug_info_urls: std::sync::Arc<Vec<PresignedUpload>>,
}

impl crate::debug_info::DebugInfoClient for PresignedDebugInfoUpload {
    /// Creates debug info links for build IDs found in NAR files.
    ///
    /// This function processes debug information from NIX store paths that contain
    /// debug symbols in the standard `lib/debug/.build-id` directory structure.
    /// It creates JSON links that allow debuggers to find debug symbols by build ID.
    ///
    /// The directory structure expected is:
    /// lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug
    /// where 'ab' are the first 2 hex characters of the build ID and the rest
    /// are the remaining 38 characters.
    ///
    /// Each debug info link contains:
    /// ```json
    /// {
    ///   "archive": "../nar-url",
    ///   "member": "lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug"
    /// }
    /// ```
    #[tracing::instrument(skip(self, nar_url, build_id, debug_path), err)]
    async fn create_debug_info_link(
        &self,
        nar_url: &str,
        build_id: String,
        debug_path: String,
    ) -> Result<(), CacheError> {
        let key = format!("debuginfo/{build_id}");
        let upload = self
            .debug_info_urls
            .iter()
            .find(|presigned| presigned.path == key)
            .ok_or(CacheError::UploadError {
                path: key.clone(),
                reason: format!("Presigned URL not found for build ID: {build_id}"),
            })?;

        let json_content = crate::debug_info::DebugInfoLink {
            archive: format!("../{nar_url}"),
            member: debug_path,
        };

        tracing::debug!("Creating debuginfo link from '{}' to '{}'", key, nar_url);
        self.client
            .upload_json(serde_json::to_string(&json_content)?, upload)
            .await?;

        Ok(())
    }
}
