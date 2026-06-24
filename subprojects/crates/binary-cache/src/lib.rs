#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use bytes::Bytes;
use object_store::{ObjectStore as _, ObjectStoreExt as _, signer::Signer as _};
use secrecy::ExposeSecret;
use smallvec::SmallVec;

use harmonia_store_path::{StoreDir, StorePath};

// Realisation writing is now done by the caller, not via FFI query.

mod cfg;
mod compression;
mod debug_info;
mod multipart;
mod narinfo;
mod presence_cache;
mod presigned;
mod streaming_hash;

pub use crate::cfg::{S3CacheConfig, S3ClientConfig, S3CredentialsConfig, S3Scheme};
pub use crate::compression::Compression;
pub use crate::debug_info::get_debug_info_build_ids;
pub use crate::multipart::{
    CompletedPart, MORE_PARTS_BATCH, MorePartsSource, MultipartCompletion, MultipartPresigner,
    PresignedMultipart, PresignedPart, S3_MAX_PARTS, WriteOutcome, part_size_for_nar,
};
use crate::narinfo::NarInfoError;
pub use crate::narinfo::{
    NarInfo, clear_sigs_and_sign, format_narinfo_txt, get_ls_path, narinfo_from_path_info,
    narinfo_simple, parse_hash, parse_nar_hash, parse_narinfo,
};
pub use crate::presigned::{
    PresignedUpload, PresignedUploadClient, PresignedUploadMetrics, PresignedUploadResponse,
    PresignedUploadResult,
};
pub use async_compression::Level as CompressionLevel;
pub use harmonia_utils_hash::{self as harmonia_utils_hash, Hash};

pub async fn path_to_narinfo(
    store: &daemon_client_utils::DaemonStoreReader,
    path: &StorePath,
) -> Result<NarInfo, CacheError> {
    let path_info = store
        .query_path_info(path)
        .await?
        .ok_or_else(|| CacheError::PathNotFound {
            path: path.to_string(),
        })?;
    let narinfo = narinfo_simple(path, path_info.info, Compression::None);
    for r in &narinfo.info.info.references {
        if !store.is_valid_path(r).await? {
            return Err(CacheError::ReferenceVerifyError(narinfo.path, r.to_owned()));
        }
    }
    Ok(narinfo)
}

#[derive(Debug, Default)]
struct AtomicS3Stats {
    put: AtomicU64,
    put_bytes: AtomicU64,
    put_time_ms: AtomicU64,
    get: AtomicU64,
    get_bytes: AtomicU64,
    get_time_ms: AtomicU64,
    head: AtomicU64,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct S3Stats {
    pub put: u64,
    pub put_bytes: u64,
    pub put_time_ms: u64,
    pub get: u64,
    pub get_bytes: u64,
    pub get_time_ms: u64,
    pub head: u64,
}

impl S3Stats {
    #[must_use]
    pub fn put_speed(&self) -> f64 {
        #[allow(clippy::cast_precision_loss)]
        if self.put_time_ms > 0 {
            self.put_bytes as f64 / self.put_time_ms as f64 * 1000.0 / (1024.0 * 1024.0)
        } else {
            0.0
        }
    }

    #[must_use]
    pub fn get_speed(&self) -> f64 {
        #[allow(clippy::cast_precision_loss)]
        if self.get_time_ms > 0 {
            self.get_bytes as f64 / self.get_time_ms as f64 * 1000.0 / (1024.0 * 1024.0)
        } else {
            0.0
        }
    }

    #[must_use]
    pub fn cost_dollar_approx(&self) -> f64 {
        #[allow(clippy::cast_precision_loss)]
        (self.get_bytes as f64 / (1024.0 * 1024.0 * 1024.0)).mul_add(
            0.09,
            ((self.get as f64 + self.head as f64) / 10000.0)
                .mul_add(0.004, self.put as f64 / 1000.0 * 0.005),
        )
    }
}

#[derive(Debug, thiserror::Error)]
pub enum CacheError {
    #[error("Object store error: {0}")]
    ObjectStore(#[from] object_store::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serde_json error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("Signing error: {0}")]
    Signing(String),
    #[error(transparent)]
    NarInfoParseError(#[from] NarInfoError),
    #[error("daemon error: {0}")]
    DaemonError(#[from] harmonia_protocol::types::DaemonError),
    #[error("presence cache error: {0}")]
    PresenceCache(#[from] sqlx::Error),
    #[error("cannot add '{0}' to the binary cache because the reference '{1}' is not valid")]
    ReferenceVerifyError(StorePath, StorePath),
    #[error("Hash error: {0}")]
    HashingError(#[from] streaming_hash::Error),
    #[error("Render error: {0}")]
    RenderError(#[from] std::fmt::Error),
    #[error("HTTP request failed: {0}")]
    HttpRequestError(#[from] reqwest::Error),
    #[error("Upload failed for {path}")]
    Upload {
        path: String,
        #[source]
        source: Box<CacheError>,
    },
    #[error("Presigned URL generation failed for {path}: {reason}")]
    PresignedUrlError { path: String, reason: String },
    #[error("Request cloning failed")]
    RequestCloneError,
    #[error("Path not found: {path}")]
    PathNotFound { path: String },
    #[error("Configuration error: {message}")]
    ConfigurationError { message: String },
    #[error("{0}")]
    Other(String),
}

/// Boxed reader over a decompressed NAR stream from the cache.
pub type NarReader = Box<dyn tokio::io::AsyncRead + Unpin + Send>;

#[derive(Debug, Clone)]
pub struct S3BinaryCacheClient {
    s3: object_store::aws::AmazonS3,
    pub cfg: Arc<S3CacheConfig>,
    s3_stats: Arc<AtomicS3Stats>,
    signing_keys: SmallVec<[secrecy::SecretString; 4]>,
    /// Persistent positive presence cache; survives restarts to avoid
    /// re-HEADing heavily-shared inputs.
    presence_cache: presence_cache::PresenceCache,
    /// Per-path single-flight locks: collapse concurrent uploads of one path.
    /// Entries live exactly as long as a lock is held (Weak, self-cleaning).
    upload_locks: Arc<
        parking_lot::Mutex<hashbrown::HashMap<StorePath, std::sync::Weak<tokio::sync::Mutex<()>>>>,
    >,
    /// `None` when no static credentials are available; large NARs then fall
    /// back to a single presigned `PUT` (which fails above S3's 5 GiB limit).
    multipart: Option<MultipartPresigner>,
}

#[tracing::instrument(skip(stream, chunk), err)]
async fn read_chunk_async<S: tokio::io::AsyncRead + Unpin + Send>(
    stream: &mut S,
    mut chunk: bytes::BytesMut,
) -> std::io::Result<Bytes> {
    use tokio::io::AsyncReadExt as _;

    while chunk.len() < chunk.capacity() {
        let read = stream.read_buf(&mut chunk).await?;

        if read == 0 {
            break;
        }
    }

    Ok(chunk.freeze())
}

#[tracing::instrument(skip(upload_item, first_chunk, stream), err)]
async fn run_multipart_upload(
    upload_item: &mut Box<dyn object_store::MultipartUpload>,
    first_chunk: Bytes,
    mut stream: &mut (dyn tokio::io::AsyncRead + Unpin + Send),
    buffer_size: usize,
) -> Result<usize, CacheError> {
    let mut part_number = 1;
    let mut first_chunk_opt = Some(first_chunk);
    let mut file_size = 0;

    loop {
        let chunk = if part_number == 1
            && let Some(first_chunk) = first_chunk_opt.take()
        {
            first_chunk
        } else {
            let buf = bytes::BytesMut::with_capacity(buffer_size);
            read_chunk_async(&mut stream, buf).await?
        };
        file_size += chunk.len();

        if chunk.is_empty() {
            break;
        }

        tracing::debug!("Uploading part {} with size {}", part_number, chunk.len());
        upload_item.put_part(chunk.into()).await?;
        part_number += 1;
    }

    tracing::debug!(
        "Completing multipart upload with {} parts, total size: {}",
        part_number,
        file_size
    );
    upload_item.complete().await?;
    Ok(file_size)
}

/// Stream a NAR by serializing the store path directly from the
/// filesystem, like harmonia-cache does when serving NARs. This avoids
/// holding a nix-daemon connection for the duration of the stream.
fn read_nar_stream(
    store_dir: &StoreDir,
    path: &StorePath,
) -> tokio_util::io::StreamReader<harmonia_file_nar::NarByteStream, Bytes> {
    let full_path = std::path::PathBuf::from(store_dir.display(path).to_string());
    tokio_util::io::StreamReader::new(harmonia_file_nar::NarByteStream::new(full_path))
}

impl S3BinaryCacheClient {
    #[tracing::instrument(skip(cfg), err)]
    fn construct_client(
        cfg: &S3ClientConfig,
    ) -> Result<object_store::aws::AmazonS3, object_store::Error> {
        let mut builder = object_store::aws::AmazonS3Builder::from_env()
            .with_region(&cfg.region)
            .with_bucket_name(&cfg.bucket)
            .with_imdsv1_fallback();

        if let Some(credentials) = &cfg.credentials {
            builder = builder
                .with_access_key_id(&credentials.access_key_id)
                .with_secret_access_key(credentials.secret_access_key.expose_secret());
        } else if std::env::var("AWS_ACCESS_KEY_ID").ok().is_none()
            && std::env::var("AWS_SECRET_ACCESS_KEY").ok().is_none()
        {
            let profile = cfg.profile.as_deref().unwrap_or("default");
            match cfg::read_aws_credentials_file(profile) {
                Ok((access_key, secret_key)) => {
                    tracing::info!(
                        "Using AWS credentials from credentials file for profile: {profile}",
                    );
                    builder = builder
                        .with_access_key_id(&access_key)
                        .with_secret_access_key(secret_key.expose_secret());
                }
                Err(e) => {
                    tracing::warn!(
                        "AWS credentials not found in environment variables or credentials file for profile: {profile}. error={e}",
                    );
                }
            }
        }

        if let Some(endpoint) = &cfg.endpoint {
            builder = builder.with_endpoint(endpoint);
            builder = builder.with_virtual_hosted_style_request(false);
        }

        if cfg.scheme == S3Scheme::HTTP {
            builder = builder.with_allow_http(true);
        }

        builder.build()
    }

    #[tracing::instrument(skip(cfg), err)]
    pub async fn new(cfg: S3CacheConfig) -> Result<Self, CacheError> {
        let mut signing_keys = SmallVec::default();
        for p in &cfg.secret_key_files {
            signing_keys.push(secrecy::SecretString::new(
                fs_err::tokio::read_to_string(p).await?.into(),
            ));
        }

        let path =
            cfg.presence_cache_path
                .as_ref()
                .ok_or_else(|| CacheError::ConfigurationError {
                    message: "presence_cache_path is required".to_string(),
                })?;
        let presence_cache =
            presence_cache::PresenceCache::open(path, cfg.presence_cache_ttl).await?;

        Ok(Self {
            s3: Self::construct_client(&cfg.client_config)?,
            multipart: MultipartPresigner::from_config(&cfg.client_config)
                .inspect_err(|e| {
                    tracing::warn!("multipart presigning disabled: {e}");
                })
                .ok(),
            presence_cache,
            cfg: cfg.into(),
            s3_stats: Arc::new(AtomicS3Stats::default()),
            signing_keys,
            upload_locks: Arc::default(),
        })
    }

    #[must_use]
    pub fn s3_stats(&self) -> S3Stats {
        S3Stats {
            put: self.s3_stats.put.load(Ordering::Relaxed),
            put_bytes: self.s3_stats.put_bytes.load(Ordering::Relaxed),
            put_time_ms: self.s3_stats.put_time_ms.load(Ordering::Relaxed),
            get: self.s3_stats.get.load(Ordering::Relaxed),
            get_bytes: self.s3_stats.get_bytes.load(Ordering::Relaxed),
            get_time_ms: self.s3_stats.get_time_ms.load(Ordering::Relaxed),
            head: self.s3_stats.head.load(Ordering::Relaxed),
        }
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn head_object(&self, key: &str) -> Result<bool, CacheError> {
        let res = self.s3.head(&object_store::path::Path::from(key)).await;
        self.s3_stats.head.fetch_add(1, Ordering::Relaxed);
        match res {
            Ok(_) => Ok(true),
            Err(object_store::Error::NotFound { .. }) => Ok(false),
            Err(e) => Err(CacheError::ObjectStore(e)),
        }
    }

    /// Size of a stored object, or `None` if absent.
    #[tracing::instrument(skip(self), err)]
    pub async fn head_object_size(&self, key: &str) -> Result<Option<u64>, CacheError> {
        let res = self.s3.head(&object_store::path::Path::from(key)).await;
        self.s3_stats.head.fetch_add(1, Ordering::Relaxed);
        match res {
            Ok(meta) => Ok(Some(meta.size)),
            Err(object_store::Error::NotFound { .. }) => Ok(None),
            Err(e) => Err(CacheError::ObjectStore(e)),
        }
    }

    /// Stream a stored object and return the sha256 and length of its bytes as
    /// stored (its `FileHash`/`FileSize`), or `None` if absent. Needed to
    /// describe a NAR a different upload wrote: the `FileHash` cannot come from
    /// a HEAD because the S3 `ETag` is an md5/multipart digest, not a sha256.
    #[tracing::instrument(skip(self), err)]
    pub async fn object_file_hash(&self, key: &str) -> Result<Option<(Hash, u64)>, CacheError> {
        use futures::StreamExt as _;
        use sha2::Digest as _;

        let get = match self.s3.get(&object_store::path::Path::from(key)).await {
            Ok(v) => v,
            Err(object_store::Error::NotFound { .. }) => return Ok(None),
            Err(e) => return Err(CacheError::ObjectStore(e)),
        };
        self.s3_stats.get.fetch_add(1, Ordering::Relaxed);
        let mut hasher = sha2::Sha256::new();
        let mut size: u64 = 0;
        let mut stream = get.into_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(CacheError::ObjectStore)?;
            size = size.saturating_add(u64::try_from(chunk.len()).unwrap_or(u64::MAX));
            hasher.update(&chunk);
        }
        let file_hash =
            Hash::from_slice(harmonia_utils_hash::Algorithm::SHA256, &hasher.finalize())
                .map_err(|e| CacheError::Signing(format!("invalid file hash: {e}")))?;
        Ok(Some((file_hash, size)))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_object(&self, key: &str) -> Result<Option<Bytes>, CacheError> {
        let start = Instant::now();
        let get_result = match self.s3.get(&object_store::path::Path::from(key)).await {
            Ok(v) => v,
            Err(object_store::Error::NotFound { .. }) => return Ok(None),
            Err(e) => return Err(CacheError::ObjectStore(e)),
        };
        let bs = get_result.bytes().await?;
        let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();

        self.s3_stats.get.fetch_add(1, Ordering::Relaxed);
        self.s3_stats.get_bytes.fetch_add(
            u64::try_from(bs.len()).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        self.s3_stats
            .get_time_ms
            .fetch_add(elapsed, Ordering::Relaxed);

        Ok(Some(bs))
    }

    #[tracing::instrument(skip(self, content, content_type), err)]
    pub async fn upsert_file<T: Into<Bytes>>(
        &self,
        name: &str,
        content: T,
        content_type: &str,
    ) -> Result<(), CacheError> {
        let stream = Box::new(std::io::Cursor::new(content.into()));
        self.upsert_file_stream(name, stream, content_type).await
    }

    #[tracing::instrument(skip(self, stream, content_type), err)]
    pub async fn upsert_file_stream(
        &self,
        name: &str,
        mut stream: Box<dyn tokio::io::AsyncBufRead + Unpin + Send>,
        content_type: &str,
    ) -> Result<(), CacheError> {
        if name.starts_with("log/") {
            let compressor = self.cfg.log_compression.get_compression_fn(
                self.cfg.get_compression_level(),
                self.cfg.parallel_compression,
            );
            let mut stream = compressor(stream);
            self.upload_file(
                name,
                &mut stream,
                content_type,
                self.cfg.log_compression.content_encoding(),
            )
            .await
        } else if std::path::Path::new(name)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("ls"))
        {
            let compressor = self.cfg.ls_compression.get_compression_fn(
                self.cfg.get_compression_level(),
                self.cfg.parallel_compression,
            );
            let mut stream = compressor(stream);
            self.upload_file(
                name,
                &mut stream,
                content_type,
                self.cfg.ls_compression.content_encoding(),
            )
            .await
        } else if std::path::Path::new(name)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("narinfo"))
        {
            let compressor = self.cfg.narinfo_compression.get_compression_fn(
                self.cfg.get_compression_level(),
                self.cfg.parallel_compression,
            );
            let mut stream = compressor(stream);
            self.upload_file(
                name,
                &mut stream,
                content_type,
                self.cfg.narinfo_compression.content_encoding(),
            )
            .await
        } else {
            self.upload_file(name, &mut stream, content_type, "").await
        }
    }

    #[tracing::instrument(skip(self, stream, content_type), err)]
    async fn upload_file(
        &self,
        name: &str,
        mut stream: &mut (dyn tokio::io::AsyncRead + Unpin + Send),
        content_type: &str,
        content_encoding: &str,
    ) -> Result<(), CacheError> {
        let start = Instant::now();
        let buf = bytes::BytesMut::with_capacity(self.cfg.buffer_size);
        let first_chunk = read_chunk_async(&mut stream, buf).await?;
        let first_chunk_len = first_chunk.len();

        if first_chunk_len < self.cfg.buffer_size {
            self.s3
                .put_opts(
                    &object_store::path::Path::from(name),
                    object_store::PutPayload::from_bytes(first_chunk.clone()),
                    object_store::PutOptions {
                        attributes: {
                            let mut attrs = object_store::Attributes::new();
                            attrs.insert(
                                object_store::Attribute::ContentType,
                                content_type.to_owned().into(),
                            );
                            if !content_encoding.is_empty() {
                                attrs.insert(
                                    object_store::Attribute::ContentEncoding,
                                    content_encoding.to_owned().into(),
                                );
                            }
                            attrs
                        },
                        ..Default::default()
                    },
                )
                .await?;

            tracing::debug!("put_object for small file -> done, size: {first_chunk_len}",);

            let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();
            self.s3_stats
                .put_time_ms
                .fetch_add(elapsed, Ordering::Relaxed);
            self.s3_stats.put.fetch_add(1, Ordering::Relaxed);
            self.s3_stats
                .put_bytes
                .fetch_add(first_chunk_len as u64, Ordering::Relaxed);

            return Ok(());
        }

        tracing::debug!(
            "Starting multipart upload for large file, first chunk size: {}",
            first_chunk_len
        );
        let mut multipart_upload = self
            .s3
            .put_multipart_opts(
                &object_store::path::Path::from(name),
                object_store::PutMultipartOptions {
                    attributes: {
                        let mut attrs = object_store::Attributes::new();
                        attrs.insert(
                            object_store::Attribute::ContentType,
                            content_type.to_owned().into(),
                        );
                        if !content_encoding.is_empty() {
                            attrs.insert(
                                object_store::Attribute::ContentEncoding,
                                content_encoding.to_owned().into(),
                            );
                        }
                        attrs
                    },
                    ..Default::default()
                },
            )
            .await?;
        match run_multipart_upload(
            &mut multipart_upload,
            first_chunk,
            stream,
            self.cfg.buffer_size,
        )
        .await
        {
            Ok(file_size) => {
                let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or_default();
                self.s3_stats
                    .put_time_ms
                    .fetch_add(elapsed, Ordering::Relaxed);
                self.s3_stats.put.fetch_add(1, Ordering::Relaxed);
                self.s3_stats
                    .put_bytes
                    .fetch_add(file_size as u64, Ordering::Relaxed);
            }
            Err(e) => {
                tracing::warn!("Upload was interrupted - Aborting multipart upload: {e}");

                if let Err(abort_err) = multipart_upload.abort().await {
                    tracing::warn!("Failed to abort multipart upload: {abort_err}");
                }

                return Err(e);
            }
        }

        Ok(())
    }

    #[tracing::instrument(skip(self, listing), err)]
    async fn upload_listing(&self, path: &str, listing: String) -> Result<(), CacheError> {
        self.upsert_file(path, listing, "application/json").await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, store_dir, narinfo), err)]
    async fn upload_narinfo(
        &self,
        store_dir: &StoreDir,
        narinfo: NarInfo,
    ) -> Result<String, CacheError> {
        let base = narinfo.path.hash().to_string();
        let info_key = format!("{base}.narinfo");
        self.upsert_file(
            &info_key,
            format_narinfo_txt(store_dir, &narinfo),
            "text/x-nix-narinfo",
        )
        .await?;
        Ok(info_key)
    }

    fn upload_lock(&self, path: &StorePath) -> Arc<tokio::sync::Mutex<()>> {
        let mut map = self.upload_locks.lock();
        if let Some(lock) = map.get(path).and_then(std::sync::Weak::upgrade) {
            return lock;
        }
        if map.len() > 1024 {
            map.retain(|_, w| w.strong_count() > 0);
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        map.insert(path.clone(), Arc::downgrade(&lock));
        lock
    }

    fn narinfo_from_valid_path_info(
        &self,
        store_dir: &StoreDir,
        vpi: &harmonia_store_path_info::ValidPathInfo,
    ) -> NarInfo {
        narinfo_from_path_info(
            &vpi.path,
            vpi.info.clone(),
            self.cfg.compression,
            store_dir,
            &self.signing_keys,
        )
    }

    #[tracing::instrument(skip(self, store_dir, vpi), fields(%vpi.path), err)]
    pub async fn copy_path(
        &self,
        store_dir: &StoreDir,
        vpi: &harmonia_store_path_info::ValidPathInfo,
        repair: bool,
    ) -> Result<(), CacheError> {
        // Serialize same-path uploads: the has_narinfo guard below is a TOCTOU.
        let lock = self.upload_lock(&vpi.path);
        let _guard = lock.lock().await;

        if !repair && self.has_narinfo(&vpi.path).await? {
            return Ok(());
        }

        tracing::debug!("start copying path: {}", vpi.path);
        let mut narinfo = self.narinfo_from_valid_path_info(store_dir, vpi);
        if self.cfg.write_nar_listing {
            let listing = nar_listing(store_dir, &narinfo.path).await?;
            let ls_json = serde_json::json!({
                "version": 1,
                "root": listing,
            });
            self.upload_listing(&get_ls_path(&narinfo), ls_json.to_string())
                .await?;
        }

        let nar_url = narinfo.info.url.clone().unwrap_or_default();
        let compression = self.cfg.compression;

        if self.cfg.write_debug_info {
            debug_info::process_debug_info(
                &nar_url,
                store_dir.as_ref(),
                &narinfo.path,
                self.clone(),
            )
            .await?;
        }

        let stream = read_nar_stream(store_dir, &narinfo.path);

        let compressor = compression.get_compression_fn(
            self.cfg.get_compression_level(),
            self.cfg.parallel_compression,
        );
        let compressed_stream = compressor(stream);
        let (mut hashing_reader, _) = streaming_hash::HashingReader::new(compressed_stream);
        // No Content-Encoding: NAR compression lives in the URL and narinfo.
        self.upload_file(
            &nar_url,
            &mut hashing_reader,
            compression.content_type(),
            "",
        )
        .await?;

        let (file_hash, file_size) = hashing_reader.finalize()?;

        if let Ok(file_hash) =
            Hash::from_slice(harmonia_utils_hash::Algorithm::SHA256, file_hash.as_slice())
        {
            narinfo.info.download_hash = Some(file_hash);
            narinfo.info.download_size = Some(file_size as u64);
        }

        // Realisation writing for CA derivations is handled by the caller
        // (e.g. the queue-runner after resolving and building a CA drv),
        // not here during path copy.

        self.upload_narinfo(store_dir, narinfo.clone()).await?;
        self.presence_cache
            .record_present(&vpi.path.hash().to_string())
            .await;

        Ok(())
    }

    #[tracing::instrument(skip(self, store_dir, paths), err)]
    pub async fn copy_paths(
        &self,
        store_dir: &StoreDir,
        paths: Vec<harmonia_store_path_info::ValidPathInfo>,
        repair: bool,
    ) -> Result<(), CacheError> {
        use futures::stream::StreamExt as _;

        let mut stream = tokio_stream::iter(paths)
            .map(|vpi| {
                let store_dir = store_dir.clone();
                async move {
                    tracing::debug!("copying path {} to s3 binary cache.", vpi.path);
                    self.copy_path(&store_dir, &vpi, repair).await
                }
            })
            .buffered(10);

        while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
            v?;
        }

        Ok(())
    }

    /// Write a pre-constructed [`Realisation`] to the binary cache.
    ///
    /// Signs the realisation with the cache's secret keys before uploading.
    #[tracing::instrument(skip(self, realisation), err)]
    pub async fn write_realisation(
        &self,
        mut realisation: harmonia_store_derivation::realisation::Realisation,
    ) -> Result<(), CacheError> {
        let keys = self
            .signing_keys
            .iter()
            .filter_map(|s| s.expose_secret().parse().ok())
            .collect::<SmallVec<[harmonia_utils_signature::SecretKey; 4]>>();
        realisation.value.sign_mut(&realisation.key, &keys);

        let json = serde_json::to_string(&realisation)?;
        let id = &realisation.key;
        self.upsert_file(&format!("realisations/{id}.doi"), json, "application/json")
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn download_narinfo(
        &self,
        store_path: &StorePath,
    ) -> Result<Option<NarInfo>, CacheError> {
        match self
            .get_object(&format!("{}.narinfo", store_path.hash()))
            .await?
        {
            Some(v) => {
                let narinfo = parse_narinfo(&v)?;
                self.presence_cache
                    .record_present(&store_path.hash().to_string())
                    .await;
                Ok(Some(narinfo))
            }
            None => Ok(None),
        }
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn download_nar(&self, nar_url: &str) -> Result<Option<Bytes>, CacheError> {
        self.get_object(nar_url).await
    }

    /// Open a streaming, decompressed reader over a store path's NAR.
    ///
    /// Unlike [`Self::download_nar`], the compressed body is not buffered in
    /// memory; it is streamed from object storage and decompressed on the fly.
    /// This keeps memory bounded for large outputs, which matters when we only
    /// need to read a handful of `nix-support/` files out of the NAR.
    ///
    /// Returns the narinfo alongside the reader so callers can use the
    /// recorded NAR/closure sizes without re-reading the archive.
    #[tracing::instrument(skip(self), err)]
    pub async fn open_nar_stream(
        &self,
        store_path: &StorePath,
    ) -> Result<Option<(NarInfo, NarReader)>, CacheError> {
        use futures::StreamExt as _;

        let Some(narinfo) = self.download_narinfo(store_path).await? else {
            return Ok(None);
        };
        let Some(url) = narinfo.info.url.clone() else {
            return Ok(None);
        };
        let compression: Compression = narinfo
            .info
            .compression
            .as_deref()
            .unwrap_or("none")
            .parse()
            .map_err(|e: compression::InvalidCompression| {
                CacheError::Other(format!("invalid narinfo compression: {e}"))
            })?;

        let get_result = match self.s3.get(&object_store::path::Path::from(url)).await {
            Ok(v) => v,
            Err(object_store::Error::NotFound { .. }) => return Ok(None),
            Err(e) => return Err(CacheError::ObjectStore(e)),
        };
        self.s3_stats.get.fetch_add(1, Ordering::Relaxed);

        let byte_stream = get_result
            .into_stream()
            .map(|r| r.map_err(std::io::Error::other));
        let reader = tokio_util::io::StreamReader::new(byte_stream);
        let buffered = tokio::io::BufReader::new(reader);
        let decoder = compression.get_decompression_fn()(buffered);
        Ok(Some((narinfo, decoder)))
    }

    /// Download and parse the `.ls` NAR listing for an output, if present.
    ///
    /// The listing is a small JSON object `{"root": <FileTree>}`; it carries
    /// the file tree with per-file sizes and types but no contents or hashes.
    /// Its compression is whatever was used at upload time, so honour the
    /// object's `Content-Encoding` and only fall back to the configured
    /// `ls_compression` when the header is absent.
    #[tracing::instrument(skip(self), err)]
    pub async fn download_listing(
        &self,
        store_path: &StorePath,
    ) -> Result<Option<harmonia_file_core::FileTree<harmonia_file_nar::NarFileInfo>>, CacheError>
    {
        use futures::StreamExt as _;
        use tokio::io::AsyncReadExt as _;

        let key = format!("{}.ls", store_path.hash());
        let get_result = match self.s3.get(&object_store::path::Path::from(key)).await {
            Ok(v) => v,
            Err(object_store::Error::NotFound { .. }) => return Ok(None),
            Err(e) => return Err(CacheError::ObjectStore(e)),
        };
        self.s3_stats.get.fetch_add(1, Ordering::Relaxed);

        let encoding = get_result
            .attributes
            .get(&object_store::Attribute::ContentEncoding)
            .map(|v| v.as_ref().to_owned());
        let compression: Compression = match encoding.as_deref() {
            Some("") | None => self.cfg.ls_compression,
            Some(e) => e.parse().map_err(|e: compression::InvalidCompression| {
                CacheError::Other(format!("invalid listing compression: {e}"))
            })?,
        };

        let byte_stream = get_result
            .into_stream()
            .map(|r| r.map_err(std::io::Error::other));
        let reader = tokio_util::io::StreamReader::new(byte_stream);
        let buffered = tokio::io::BufReader::new(reader);
        let mut decoder = compression.get_decompression_fn()(buffered);

        let mut bytes = Vec::new();
        decoder
            .read_to_end(&mut bytes)
            .await
            .map_err(|e| CacheError::Other(format!("reading listing: {e}")))?;

        #[derive(serde::Deserialize)]
        struct Listing {
            root: harmonia_file_core::FileTree<harmonia_file_nar::NarFileInfo>,
        }
        let listing: Listing = serde_json::from_slice(&bytes)
            .map_err(|e| CacheError::Other(format!("parsing listing JSON: {e}")))?;
        Ok(Some(listing.root))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn has_narinfo(&self, store_path: &StorePath) -> Result<bool, CacheError> {
        let hash = store_path.hash().to_string();
        if self.presence_cache.is_present(&hash).await {
            return Ok(true);
        }
        let present = self.head_object(&format!("{hash}.narinfo")).await?;
        if present {
            self.presence_cache.record_present(&hash).await;
        }
        Ok(present)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn download_realisation(
        &self,
        id: &harmonia_store_derivation::realisation::DrvOutput,
    ) -> Result<Option<Bytes>, CacheError> {
        self.get_object(&format!("realisations/{id}.doi")).await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn has_realisation(
        &self,
        id: &harmonia_store_derivation::realisation::DrvOutput,
    ) -> Result<bool, CacheError> {
        Ok(self.download_realisation(id).await?.is_some())
    }

    #[tracing::instrument(skip(self, paths))]
    pub async fn query_missing_paths(&self, paths: Vec<StorePath>) -> Vec<StorePath> {
        use futures::stream::StreamExt as _;

        tokio_stream::iter(paths)
            .map(|p| async move {
                match self.has_narinfo(&p).await {
                    Ok(true) => None,
                    Ok(false) => Some(p),
                    // Error != absent: skip this cycle, don't re-upload a present path.
                    Err(e) => {
                        tracing::warn!(
                            "has_narinfo({p}) failed, skipping upload this cycle: {e:#}"
                        );
                        None
                    }
                }
            })
            .buffered(50)
            .filter_map(|p| async { p })
            .collect()
            .await
    }

    #[tracing::instrument(skip(self, outputs))]
    pub async fn query_missing_remote_outputs(
        &self,
        outputs: BTreeMap<harmonia_store_derivation::derived_path::OutputName, Option<StorePath>>,
    ) -> BTreeMap<harmonia_store_derivation::derived_path::OutputName, Option<StorePath>> {
        use futures::stream::StreamExt as _;

        tokio_stream::iter(outputs)
            .map(|(name, path)| async move {
                match path {
                    Some(p) => match self.has_narinfo(&p).await {
                        Ok(true) => None,
                        Ok(false) => Some((name, Some(p))),
                        Err(e) => {
                            tracing::warn!(
                                "has_narinfo({p}) failed, skipping upload this cycle: {e:#}"
                            );
                            None
                        }
                    },
                    None => Some((name, None)),
                }
            })
            .buffered(50)
            .filter_map(|o| async { o })
            .collect()
            .await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn generate_nar_upload_presigned_url(
        &self,
        path: &StorePath,
        nar_hash: &harmonia_store_path_info::NarHash,
        nar_size: u64,
        debug_info_build_ids: Vec<String>,
    ) -> Result<PresignedUploadResponse, CacheError> {
        use harmonia_utils_hash::HashFormat as _;
        let h: Hash = (*nar_hash).into();
        let nar_hash_url = format!("{:#}", h.as_base32());

        let nar_url = format!("nar/{}.{}", nar_hash_url, self.cfg.compression.ext());
        let url = self
            .s3
            .signed_url(
                reqwest::Method::PUT,
                &object_store::path::Path::from(nar_url.as_str()),
                self.cfg.presigned_url_expiry,
            )
            .await
            .map_err(|e| CacheError::PresignedUrlError {
                path: path.to_string(),
                reason: format!("Failed to generate presigned URL for NAR: {e}"),
            })?;

        let multipart = self.create_multipart(&nar_url, nar_size).await?;
        let ls_upload = if self.cfg.write_nar_listing {
            let s3_file_path = format!("{}.ls", path.hash());
            Some(PresignedUpload {
                url: self
                    .s3
                    .signed_url(
                        reqwest::Method::PUT,
                        &object_store::path::Path::from(s3_file_path.as_str()),
                        self.cfg.presigned_url_expiry,
                    )
                    .await
                    .map_err(|e| CacheError::PresignedUrlError {
                        path: s3_file_path.clone(),
                        reason: format!("Failed to generate presigned URL for listing: {e}"),
                    })?
                    .to_string(),
                path: s3_file_path,
                compression: self.cfg.ls_compression,
                compression_level: self.cfg.get_compression_level(),
                multipart: None,
            })
        } else {
            None
        };
        let debug_info_upload = if self.cfg.write_debug_info && !debug_info_build_ids.is_empty() {
            use futures::stream::StreamExt as _;

            let mut o = Vec::with_capacity(debug_info_build_ids.len());
            let mut stream = tokio_stream::iter(debug_info_build_ids)
                .map(|build_id| async move {
                    let s3_file_path = format!("debuginfo/{build_id}");
                    // if this request fails, we assume default, which will then override the file
                    if self.head_object(&s3_file_path).await.unwrap_or_default() {
                        Ok(None)
                    } else {
                        Ok::<_, CacheError>(Some(PresignedUpload {
                            url: self
                                .s3
                                .signed_url(
                                    reqwest::Method::PUT,
                                    &object_store::path::Path::from(s3_file_path.as_str()),
                                    self.cfg.presigned_url_expiry,
                                )
                                .await?
                                .to_string(),
                            path: s3_file_path,
                            compression: Compression::None,
                            compression_level: async_compression::Level::Default,
                            multipart: None,
                        }))
                    }
                })
                .buffered(10);

            while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
                if let Some(v) = v? {
                    o.push(v);
                }
            }
            o
        } else {
            vec![]
        };

        Ok(PresignedUploadResponse {
            nar_url: nar_url.clone(), // we could deduplicate this, but its not that big of a deal
            nar_upload: PresignedUpload {
                path: nar_url,
                url: url.to_string(),
                compression: self.cfg.compression,
                compression_level: self.cfg.get_compression_level(),
                multipart,
            },
            ls_upload,
            debug_info_upload,
        })
    }

    /// Initiate a multipart upload so the compressed NAR streams to S3
    /// part-by-part instead of being buffered whole in memory. Returns `None`
    /// only when no multipart presigner is configured, in which case the caller
    /// falls back to a single buffered `PUT`.
    async fn create_multipart(
        &self,
        nar_url: &str,
        nar_size: u64,
    ) -> Result<Option<PresignedMultipart>, CacheError> {
        let Some(presigner) = &self.multipart else {
            return Ok(None);
        };
        Ok(Some(
            presigner
                .create(
                    nar_url,
                    self.cfg.compression.content_type(),
                    // No Content-Encoding: NAR compression lives in the URL + narinfo.
                    "",
                    nar_size,
                    self.cfg.presigned_url_expiry,
                )
                .await?,
        ))
    }

    /// Presign more `UploadPart` URLs for an in-progress multipart upload.
    pub fn presign_more_multipart_parts(
        &self,
        key: &str,
        upload_id: &str,
        start_part: u32,
        count: u32,
    ) -> Result<Vec<PresignedPart>, CacheError> {
        let presigner = self.require_multipart()?;
        let end = start_part.saturating_add(count.saturating_sub(1));
        presigner.presign_parts(
            key,
            upload_id,
            start_part..=end,
            self.cfg.presigned_url_expiry,
        )
    }

    /// Finalise a multipart upload from the builder-reported part `ETag`s.
    pub async fn complete_multipart_upload(
        &self,
        key: &str,
        upload_id: &str,
        parts: Vec<CompletedPart>,
    ) -> Result<WriteOutcome, CacheError> {
        self.require_multipart()?
            .complete(key, upload_id, parts)
            .await
    }

    fn require_multipart(&self) -> Result<&MultipartPresigner, CacheError> {
        self.multipart
            .as_ref()
            .ok_or_else(|| CacheError::ConfigurationError {
                message: "multipart uploads require static S3 credentials".to_owned(),
            })
    }

    #[tracing::instrument(skip(self, connector, narinfo), err)]
    pub async fn upload_narinfo_after_presigned_upload(
        &self,
        connector: &daemon_client_utils::DaemonConnector,
        mut narinfo: NarInfo,
        nar_already_present: bool,
    ) -> Result<String, CacheError> {
        // Same single-flight + skip-if-present as copy_path: concurrent builder
        // reports for one output path must not each rewrite the narinfo.
        let lock = self.upload_lock(&narinfo.path);
        let _guard = lock.lock().await;
        let narinfo_key = format!("{}.narinfo", narinfo.path.hash());
        if self.has_narinfo(&narinfo.path).await? {
            return Ok(narinfo_key);
        }

        if self.cfg.write_nar_listing {
            let ls_path = get_ls_path(&narinfo);
            self.head_object(&ls_path)
                .await?
                .then_some(())
                .ok_or(CacheError::PathNotFound { path: ls_path })?;
        }
        let nar_url = narinfo.info.url.clone().unwrap_or_default();
        let missing = || CacheError::PathNotFound {
            path: nar_url.clone(),
        };

        // FileHash/FileSize must describe the stored object, not this upload's
        // (possibly discarded) compression. The NAR is write-once: when it was
        // already present another upload's compression is stored, so recompute
        // its hash; otherwise our reported FileHash is correct and we only
        // confirm the size.
        let file_size = if nar_already_present {
            let (file_hash, file_size) =
                self.object_file_hash(&nar_url).await?.ok_or_else(missing)?;
            narinfo.info.download_hash = Some(file_hash);
            file_size
        } else {
            self.head_object_size(&nar_url).await?.ok_or_else(missing)?
        };
        narinfo.info.download_size = Some(file_size);

        let narinfo = clear_sigs_and_sign(narinfo, connector.store_dir(), &self.signing_keys);
        // TODO: we also need to integrate realisation into this!
        let path = narinfo.path.clone();
        let key = self
            .upload_narinfo(connector.store_dir(), narinfo.clone())
            .await?;
        self.presence_cache
            .record_present(&path.hash().to_string())
            .await;
        Ok(key)
    }
}

impl debug_info::DebugInfoClient for S3BinaryCacheClient {
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

        if self.head_object(&key).await? {
            tracing::debug!("Debuginfo link {} already exists, skipping", key);
            return Ok(());
        }

        let json_content = debug_info::DebugInfoLink {
            archive: format!("../{nar_url}"),
            member: debug_path,
        };

        tracing::debug!("Creating debuginfo link from '{}' to '{}'", key, nar_url);

        self.upsert_file(
            &key,
            serde_json::to_string(&json_content)?,
            "application/json",
        )
        .await?;

        Ok(())
    }
}

/// Generate a NAR listing by serializing the store path from the filesystem.
async fn nar_listing(
    store_dir: &StoreDir,
    path: &StorePath,
) -> Result<harmonia_file_core::FileTree<harmonia_file_nar::NarFileInfo>, CacheError> {
    let reader = harmonia_utils_io::BytesReader::new(read_nar_stream(store_dir, path));
    let listing = harmonia_file_nar::parse_nar_listing(reader).await?;

    Ok(listing)
}
