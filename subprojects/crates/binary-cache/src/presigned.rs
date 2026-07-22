use std::sync::atomic::{AtomicU64, Ordering};

use backon::Retryable;
use bytes::Bytes;
use harmonia_store_path::StorePath;

use crate::multipart::{
    CompletedPart, MORE_PARTS_BATCH, MorePartsSource, MultipartCompletion, PresignedMultipart,
};
use crate::{CacheError, Compression, read_nar_stream, streaming_hash::HashingReader};

/// Multipart part PUTs kept in flight per NAR; reads stay sequential.
const PART_UPLOAD_CONCURRENCY: usize = 8;

const RETRY_MIN_DELAY_SECS: u64 = 1;
const RETRY_MAX_DELAY_SECS: u64 = 30;
const RETRY_MAX_ATTEMPTS: usize = 3;

#[derive(Debug, Clone)]
pub struct PresignedUpload {
    pub path: String,
    pub url: String,
    pub compression: Compression,
    pub compression_level: async_compression::Level,
    /// Set on the NAR upload when the object is large enough to need multipart;
    /// the single presigned `PUT` in `url` is then unused.
    pub multipart: Option<PresignedMultipart>,
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
            multipart: None,
        }
    }

    #[must_use]
    pub fn with_multipart(mut self, multipart: Option<PresignedMultipart>) -> Self {
        self.multipart = multipart;
        self
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

#[derive(Debug, Clone, Copy)]
pub struct PresignedUploadResult {
    pub file_hash: harmonia_utils_hash::Hash,
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

    #[tracing::instrument(skip(self, store_dir, narinfo, req, more_parts), err)]
    pub async fn process_presigned_request(
        &self,
        store_dir: &harmonia_store_path::StoreDir,
        mut narinfo: crate::NarInfo,
        req: PresignedUploadResponse,
        more_parts: &dyn MorePartsSource,
    ) -> Result<(crate::NarInfo, Option<MultipartCompletion>, bool), CacheError> {
        narinfo.info.url = Some(req.nar_url.clone());
        narinfo.info.compression = Some(req.nar_upload.compression.as_str().to_owned());

        if let Some(ls_upload) = req.ls_upload {
            self.upload_ls(store_dir, &narinfo.path, &ls_upload).await?;
        }

        if !req.debug_info_upload.is_empty() {
            let debug_info_client = PresignedDebugInfoUpload {
                client: self.clone(),
                debug_info_urls: std::sync::Arc::new(req.debug_info_upload),
            };
            crate::debug_info::process_debug_info(
                &req.nar_url,
                store_dir.as_ref(),
                &narinfo.path,
                debug_info_client.clone(),
            )
            .await?;
        }

        let (upload_res, completion, nar_already_present) = self
            .upload_nar(store_dir, &narinfo.path, &req.nar_upload, more_parts)
            .await?;
        narinfo.info.download_hash = Some(upload_res.file_hash);
        narinfo.info.download_size = Some(upload_res.file_size);

        Ok((narinfo, completion, nar_already_present))
    }

    #[tracing::instrument(skip(self, store_dir, store_path, more_parts), err)]
    async fn upload_nar(
        &self,
        store_dir: &harmonia_store_path::StoreDir,
        store_path: &StorePath,
        upload: &PresignedUpload,
        more_parts: &dyn MorePartsSource,
    ) -> Result<(PresignedUploadResult, Option<MultipartCompletion>, bool), CacheError> {
        let start = std::time::Instant::now();

        let stream = read_nar_stream(store_dir, store_path);
        let compressor = upload
            .compression
            .get_compression_fn(upload.compression_level, false);
        let compressed_stream = compressor(stream);
        let (hashing_reader, _) = HashingReader::new(compressed_stream);

        if let Some(multipart) = &upload.multipart {
            // Multipart objects are finalised server-side; whether the NAR was
            // already present is decided there by the conditional Complete.
            let (res, completion) = self
                .upload_nar_multipart(hashing_reader, start, multipart, more_parts)
                .await?;
            Ok((res, Some(completion), false))
        } else {
            let (res, already_present) = self
                .upload_any(upload, hashing_reader, start, None, true)
                .await?;
            Ok((res, None, already_present))
        }
    }

    /// Stream the compressed NAR to S3 as multipart parts, collecting `ETag`s
    /// and requesting more presigned URLs if the part estimate falls short.
    #[tracing::instrument(skip(self, reader, start, multipart, more_parts), err)]
    async fn upload_nar_multipart(
        &self,
        mut reader: HashingReader<Box<dyn tokio::io::AsyncRead + Send + Unpin>>,
        start: std::time::Instant,
        multipart: &PresignedMultipart,
        more_parts: &dyn MorePartsSource,
    ) -> Result<(PresignedUploadResult, MultipartCompletion), CacheError> {
        use futures::stream::StreamExt as _;
        use tokio::io::AsyncReadExt as _;

        let part_size = usize::try_from(multipart.part_size).unwrap_or(usize::MAX);
        let mut urls: Vec<String> = multipart.parts.iter().map(|p| p.url.clone()).collect();
        let mut completed = Vec::new();
        let mut part_number: u32 = 1;

        let mut inflight = futures::stream::FuturesUnordered::new();

        loop {
            let mut buf = bytes::BytesMut::with_capacity(part_size);
            while buf.len() < part_size {
                let n = reader.read_buf(&mut buf).await?;
                if n == 0 {
                    break;
                }
            }
            // No more data: a NAR always has at least one part, so only stop
            // once we have uploaded something.
            if buf.is_empty() && part_number > 1 {
                break;
            }
            let last = buf.len() < part_size;

            let idx = (part_number - 1) as usize;
            if idx >= urls.len() {
                let extra = more_parts
                    .more_parts(&multipart.upload_id, part_number, MORE_PARTS_BATCH)
                    .await?;
                if extra.is_empty() {
                    return Err(CacheError::PresignedUrlError {
                        path: multipart.key.clone(),
                        reason: "ran out of presigned multipart URLs".to_owned(),
                    });
                }
                urls.extend(extra.into_iter().map(|p| p.url));
            }

            let url = urls[idx].clone();
            let data = buf.freeze();
            let pn = part_number;
            inflight.push(async move { self.put_part(&url, data).await.map(|etag| (pn, etag)) });

            if inflight.len() >= PART_UPLOAD_CONCURRENCY
                && let Some(res) = inflight.next().await
            {
                let (pn, etag) = res?;
                completed.push(CompletedPart {
                    part_number: pn,
                    etag,
                });
            }

            if last {
                break;
            }
            part_number += 1;
        }

        while let Some(res) = inflight.next().await {
            let (pn, etag) = res?;
            completed.push(CompletedPart {
                part_number: pn,
                etag,
            });
        }
        completed.sort_by_key(|p| p.part_number);

        let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();
        let (file_hash, file_size) = reader.finalize()?;
        let file_hash = harmonia_utils_hash::Hash::from_slice(
            harmonia_utils_hash::Algorithm::SHA256,
            file_hash.as_slice(),
        )
        .map_err(|e| CacheError::Signing(format!("invalid file hash: {e}")))?;

        let file_size = file_size as u64;
        self.metrics
            .put_bytes
            .fetch_add(file_size, Ordering::Relaxed);
        self.metrics
            .put_time_ms
            .fetch_add(elapsed, Ordering::Relaxed);
        self.metrics.put.fetch_add(1, Ordering::Relaxed);

        Ok((
            PresignedUploadResult {
                file_hash,
                file_size,
            },
            MultipartCompletion {
                key: multipart.key.clone(),
                upload_id: multipart.upload_id.clone(),
                parts: completed,
            },
        ))
    }

    /// PUT one part and return its (quote-stripped) `ETag`.
    async fn put_part(&self, url: &str, data: Bytes) -> Result<String, CacheError> {
        let response = (|| async {
            Ok::<_, CacheError>(
                self.client
                    .put(url)
                    .body(data.clone())
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

        response
            .headers()
            .get(reqwest::header::ETAG)
            .and_then(|v| v.to_str().ok())
            .map(|etag| etag.trim_matches('"').to_owned())
            .ok_or_else(|| CacheError::PresignedUrlError {
                path: url.to_owned(),
                reason: "UploadPart response missing ETag".to_owned(),
            })
    }

    #[tracing::instrument(skip(self, store_dir), err)]
    async fn upload_ls(
        &self,
        store_dir: &harmonia_store_path::StoreDir,
        path: &StorePath,
        upload: &PresignedUpload,
    ) -> Result<PresignedUploadResult, CacheError> {
        let start = std::time::Instant::now();

        let listing = super::nar_listing(store_dir, path).await?;
        let ls_json = serde_json::json!({
            "version": 1,
            "root": listing,
        });
        let stream = Box::new(std::io::Cursor::new(Bytes::from(ls_json.to_string())));
        let compressor = upload
            .compression
            .get_compression_fn(upload.compression_level, false);
        let compressed_stream = compressor(stream);
        let (hashing_reader, _) = HashingReader::new(compressed_stream);

        let (res, _) = self
            .upload_any(
                upload,
                hashing_reader,
                start,
                Some("application/json"),
                false,
            )
            .await?;
        Ok(res)
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

        let (res, _) = self
            .upload_any(
                upload,
                hashing_reader,
                start,
                Some("application/json"),
                false,
            )
            .await?;
        Ok(res)
    }

    /// Upload a single presigned PUT. When `conditional`, the request carries
    /// `If-None-Match: *` so a content-addressed object is written at most once;
    /// a 412 is reported back as `already_present` instead of an error so the
    /// caller can avoid describing bytes a different upload already stored.
    #[tracing::instrument(skip(self, start, reader), err)]
    async fn upload_any(
        &self,
        upload: &PresignedUpload,
        mut reader: HashingReader<Box<dyn tokio::io::AsyncRead + Send + Unpin>>,
        start: std::time::Instant,
        content_type: Option<&str>,
        conditional: bool,
    ) -> Result<(PresignedUploadResult, bool), CacheError> {
        // Clippy has a false positive and suggests using blocks,
        // but that would not allow processing errors from the ? operator to add context
        #[allow(clippy::redundant_closure_call)]
        async move || -> Result<(PresignedUploadResult, bool), CacheError> {
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
            if conditional {
                request = request.header("If-None-Match", "*");
            }

            // TODO: We need multipart signed urls to fix this!
            //       object_store currently doesnt have support for this.
            let mut buffer = Vec::new();
            reader.read_to_end(&mut buffer).await?;

            let response = (|| async {
                let resp = request
                    .try_clone()
                    .ok_or_else(|| CacheError::RequestCloneError)?
                    .body(buffer.clone())
                    .send()
                    .await?;
                // A conditional write that loses the race is terminal, not a
                // transient error, so return it without retrying.
                if resp.status() == reqwest::StatusCode::PRECONDITION_FAILED {
                    return Ok::<_, CacheError>(resp);
                }
                Ok(resp.error_for_status()?)
            })
            .retry(
                &backon::ExponentialBuilder::default()
                    .with_min_delay(std::time::Duration::from_secs(RETRY_MIN_DELAY_SECS))
                    .with_max_delay(std::time::Duration::from_secs(RETRY_MAX_DELAY_SECS))
                    .with_max_times(RETRY_MAX_ATTEMPTS),
            )
            .await?;
            let already_present = response.status() == reqwest::StatusCode::PRECONDITION_FAILED;

            let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();

            let (file_hash, file_size) = reader.finalize()?;

            let file_hash = harmonia_utils_hash::Hash::from_slice(
                harmonia_utils_hash::Algorithm::SHA256,
                file_hash.as_slice(),
            )
            .map_err(|e| CacheError::Signing(format!("invalid file hash: {e}")))?;

            // Update metrics
            self.metrics
                .put_bytes
                .fetch_add(file_size as u64, Ordering::Relaxed);
            self.metrics
                .put_time_ms
                .fetch_add(elapsed, Ordering::Relaxed);
            self.metrics.put.fetch_add(1, Ordering::Relaxed);

            Ok((
                PresignedUploadResult {
                    file_hash,
                    file_size: file_size as u64,
                },
                already_present,
            ))
        }()
        .await
        .map_err(|source| CacheError::Upload {
            path: upload.url.clone(),
            source: source.into(),
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
            .ok_or(CacheError::PresignedUrlError {
                path: key.clone(),
                reason: "Presigned URL not found".to_string(),
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
