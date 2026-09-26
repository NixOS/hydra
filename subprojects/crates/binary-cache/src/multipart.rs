//! Presigned S3 multipart uploads.
//!
//! A presigned `PUT` is capped at 5 GiB, so builders upload NARs in parts.
//! The queue runner creates the upload, presigns `UploadPart` URLs for the
//! builder with [`Signer::signed_url_opts`], and completes it from the `ETag`s
//! the builder reports.
//!
//! The queue runner sends completion and cross-bucket copy requests itself,
//! because `object_store` can't complete with `If-None-Match` or copy between
//! buckets.
//!
//! [`Signer::signed_url_opts`]: object_store::signer::Signer::signed_url_opts

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use object_store::aws::AmazonS3;
use object_store::multipart::MultipartStore as _;
use object_store::path::Path;
use object_store::signer::{HeaderName, HeaderValue, Method, SignedUrlOptions, Signer as _, Url};
use object_store::{Attribute, Attributes, PutMultipartOptions};

use crate::CacheError;

const MIN_PART_SIZE: u64 = 10 * 1024 * 1024;
const MAX_PART_SIZE: u64 = 5 * 1024 * 1024 * 1024;
/// Largest object a single server-side `CopyObject` may cover.
/// Larger objects are copied with multipart `UploadPartCopy`.
const MAX_COPY_OBJECT_SIZE: u64 = 5 * 1024 * 1024 * 1024;
/// Source range covered by one `UploadPartCopy` request.
const COPY_PART_SIZE: u64 = 1024 * 1024 * 1024;
/// S3 allows at most 10 000 parts. Aim for 9000 so an incompressible NAR that
/// zstd grows slightly still fits the presigned part count without a refill.
const TARGET_MAX_PARTS: u64 = 9000;
pub const S3_MAX_PARTS: u32 = 10_000;
/// Expiry of URLs for requests the queue runner sends itself.
const SERVER_REQUEST_EXPIRY: Duration = Duration::from_mins(15);
const COPY_SOURCE: HeaderName = HeaderName::from_static("x-amz-copy-source");
const COPY_SOURCE_RANGE: HeaderName = HeaderName::from_static("x-amz-copy-source-range");

/// Part size for a NAR of `nar_size` uncompressed bytes. The compressed size is
/// unknown up front, but the uncompressed size is a safe upper bound; rounding
/// to 16 MiB steps (like minio-go) keeps the part count under [`TARGET_MAX_PARTS`].
#[must_use]
pub fn part_size_for_nar(nar_size: u64) -> u64 {
    const STEP: u64 = 16 * 1024 * 1024;
    let size = nar_size.div_ceil(TARGET_MAX_PARTS);
    if size <= MIN_PART_SIZE {
        return MIN_PART_SIZE;
    }
    size.div_ceil(STEP).saturating_mul(STEP).min(MAX_PART_SIZE)
}

/// A presigned `UploadPart` URL. Part numbers are 1-based.
#[derive(Debug, Clone)]
pub struct PresignedPart {
    pub part_number: u32,
    pub url: String,
}

/// An in-progress multipart upload handed to the builder.
#[derive(Debug, Clone)]
pub struct PresignedMultipart {
    pub key: String,
    pub upload_id: String,
    pub part_size: u64,
    pub parts: Vec<PresignedPart>,
}

/// One finished part, reported by the builder for completion.
#[derive(Debug, Clone)]
pub struct CompletedPart {
    pub part_number: u32,
    pub etag: String,
}

/// Whether finalising a write-once object actually wrote it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteOutcome {
    /// This request wrote the object.
    Created,
    /// The object already existed (the conditional write returned 412); a
    /// different upload's compression is what is stored.
    AlreadyExists,
}

/// What the builder reports back so the server can finalise the upload.
#[derive(Debug, Clone)]
pub struct MultipartCompletion {
    pub key: String,
    pub upload_id: String,
    pub parts: Vec<CompletedPart>,
}

/// Batch size when the builder runs out of presigned part URLs mid-upload.
pub const MORE_PARTS_BATCH: u32 = 100;

/// Source of additional presigned part URLs, implemented by the builder over
/// its gRPC channel. Needed because the compressed size is unknown up front, so
/// the server's initial part estimate may (rarely) fall short.
pub trait MorePartsSource: Send + Sync {
    fn more_parts<'a>(
        &'a self,
        upload_id: &'a str,
        start_part: u32,
        count: u32,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<PresignedPart>, CacheError>> + Send + 'a>>;
}

/// Signs with the cache's `object_store` client, so any credential source it
/// supports works.
#[derive(Debug, Clone)]
pub(crate) struct MultipartPresigner {
    s3: AmazonS3,
    http_client: reqwest::Client,
}

impl MultipartPresigner {
    pub(crate) fn new(s3: AmazonS3) -> Self {
        Self {
            s3,
            http_client: reqwest::Client::new(),
        }
    }

    async fn presign(
        &self,
        method: Method,
        key: &str,
        options: &SignedUrlOptions,
        expires: Duration,
    ) -> Result<Url, CacheError> {
        self.s3
            .signed_url_opts(method, &Path::from(key), expires, options)
            .await
            .map_err(|e| presign_err(key, e))
    }

    /// Builds a request to a short-lived presigned URL and sets the signed headers on it.
    async fn signed_request(
        &self,
        method: Method,
        key: &str,
        options: SignedUrlOptions,
    ) -> Result<reqwest::RequestBuilder, CacheError> {
        let url = self
            .presign(method.clone(), key, &options, SERVER_REQUEST_EXPIRY)
            .await?;
        Ok(self
            .http_client
            .request(method, url)
            .headers(options.signed_headers))
    }

    async fn send_signed(
        &self,
        method: Method,
        key: &str,
        options: SignedUrlOptions,
    ) -> Result<String, CacheError> {
        let body = self
            .signed_request(method, key, options)
            .await?
            .send()
            .await
            .map_err(|e| presign_err(key, e))?
            .error_for_status()
            .map_err(|e| presign_err(key, e))?
            .text()
            .await
            .map_err(|e| presign_err(key, e))?;
        // Copy operations may return 200 OK with an <Error> element in the body.
        if let Ok(error) = quick_xml::de::from_str::<S3ErrorResponse>(&body) {
            return Err(CacheError::Other(format!(
                "S3 request for {key} failed: {} ({})",
                error.message, error.code
            )));
        }
        Ok(body)
    }

    /// Server-side copy of `key` from `source_bucket` (same endpoint) into this
    /// bucket: `CopyObject`, or `UploadPartCopy` above the single-copy limit.
    /// `CopyObject` keeps the source's metadata; multipart copies get `attributes`.
    #[tracing::instrument(skip(self, attributes), err)]
    pub(crate) async fn copy_object_from(
        &self,
        source_bucket: &str,
        key: &str,
        size: u64,
        attributes: Attributes,
    ) -> Result<(), CacheError> {
        let copy_source = HeaderValue::try_from(format!("/{source_bucket}/{key}"))
            .map_err(|e| presign_err(key, e))?;
        let options = SignedUrlOptions::default().with_signed_header(COPY_SOURCE, copy_source);

        if size <= MAX_COPY_OBJECT_SIZE {
            self.send_signed(Method::PUT, key, options).await?;
            return Ok(());
        }

        let upload_id = self.initiate_upload(key, attributes).await?;
        let mut parts = Vec::new();
        let mut start = 0u64;
        let mut part_number = 1u32;
        while start < size {
            let end = start.saturating_add(COPY_PART_SIZE).min(size) - 1;
            let part_options = options
                .clone()
                .with_query([
                    ("partNumber", part_number.to_string()),
                    ("uploadId", upload_id.clone()),
                ])
                .with_signed_header(
                    COPY_SOURCE_RANGE,
                    HeaderValue::try_from(format!("bytes={start}-{end}"))
                        .map_err(|e| presign_err(key, e))?,
                );
            let body = self.send_signed(Method::PUT, key, part_options).await?;
            let result: CopyResult = quick_xml::de::from_str(&body).map_err(|e| {
                CacheError::Other(format!("invalid UploadPartCopy response for {key}: {e}"))
            })?;
            parts.push(CompletedPart {
                part_number,
                etag: result.etag,
            });
            start = end + 1;
            part_number += 1;
        }
        self.complete(key, &upload_id, parts).await?;
        Ok(())
    }

    /// Initiate a multipart upload and presign the part URLs the builder needs.
    #[tracing::instrument(skip(self), err)]
    pub(crate) async fn create(
        &self,
        key: &str,
        content_type: &str,
        nar_size: u64,
        expires: Duration,
    ) -> Result<PresignedMultipart, CacheError> {
        // NARs get no Content-Encoding, because their compression is in the URL and narinfo.
        let attributes = Attributes::from_iter([(Attribute::ContentType, content_type.to_owned())]);
        let upload_id = self.initiate_upload(key, attributes).await?;

        let part_size = part_size_for_nar(nar_size);
        let part_count = estimated_part_count(nar_size, part_size);
        let parts = self
            .presign_parts(key, &upload_id, 1..=part_count, expires)
            .await?;

        Ok(PresignedMultipart {
            key: key.to_owned(),
            upload_id,
            part_size,
            parts,
        })
    }

    /// Presign additional `UploadPart` URLs for an in-progress upload.
    pub(crate) async fn presign_parts(
        &self,
        key: &str,
        upload_id: &str,
        part_numbers: std::ops::RangeInclusive<u32>,
        expires: Duration,
    ) -> Result<Vec<PresignedPart>, CacheError> {
        let mut parts = Vec::new();
        for part_number in part_numbers {
            // S3 rejects UploadPart unless partNumber and uploadId are signed.
            let options = SignedUrlOptions::default().with_query([
                ("partNumber", part_number.to_string()),
                ("uploadId", upload_id.to_owned()),
            ]);
            let url = self.presign(Method::PUT, key, &options, expires).await?;
            parts.push(PresignedPart {
                part_number,
                url: url.into(),
            });
        }
        Ok(parts)
    }

    /// Finalise the upload from the builder-reported part `ETag`s, sent with
    /// `If-None-Match: *` so `nar/<hash>` is write-once and never overwritten
    /// with a different compression (which would diverge from Fastly's cached
    /// copy). A 412 means another upload already stored a valid compression, so
    /// it counts as success: the object decompresses to the same `NarHash`.
    #[tracing::instrument(skip(self, parts), err)]
    pub(crate) async fn complete(
        &self,
        key: &str,
        upload_id: &str,
        mut parts: Vec<CompletedPart>,
    ) -> Result<WriteOutcome, CacheError> {
        parts.sort_by_key(|p| p.part_number);
        let body = complete_multipart_xml(&parts);

        let options = SignedUrlOptions::default().with_query([("uploadId", upload_id)]);
        let response = self
            .signed_request(Method::POST, key, options)
            .await?
            .header("Content-Type", "application/xml")
            .header("If-None-Match", "*")
            .body(body)
            .send()
            .await
            .map_err(|e| presign_err(key, e))?;
        if response.status() == reqwest::StatusCode::PRECONDITION_FAILED {
            return Ok(WriteOutcome::AlreadyExists);
        }
        response
            .error_for_status()
            .map_err(|e| presign_err(key, e))?;
        Ok(WriteOutcome::Created)
    }

    /// Execute `CreateMultipartUpload` and return the `UploadId`.
    async fn initiate_upload(
        &self,
        key: &str,
        attributes: Attributes,
    ) -> Result<String, CacheError> {
        Ok(self
            .s3
            .create_multipart_opts(
                &Path::from(key),
                PutMultipartOptions {
                    attributes,
                    ..Default::default()
                },
            )
            .await?)
    }
}

/// `CopyObjectResult` / `CopyPartResult` response body.
#[derive(Debug, serde::Deserialize)]
struct CopyResult {
    #[serde(rename = "ETag")]
    etag: String,
}

/// S3 `<Error>` body, which copy operations may return with a 200 status.
#[derive(Debug, serde::Deserialize)]
struct S3ErrorResponse {
    #[serde(rename = "Code")]
    code: String,
    #[serde(rename = "Message", default)]
    message: String,
}

fn presign_err(path: &str, e: impl std::fmt::Display) -> CacheError {
    CacheError::PresignedUrlError {
        path: path.to_owned(),
        reason: e.to_string(),
    }
}

/// Parts to presign for `nar_size`, with headroom for slight `zstd` expansion
/// of incompressible data; the builder asks for more if it still runs out.
fn estimated_part_count(nar_size: u64, part_size: u64) -> u32 {
    let parts = nar_size.div_ceil(part_size.max(1)).max(1);
    let with_headroom = parts.saturating_add(parts.div_ceil(10)).saturating_add(1);
    u32::try_from(with_headroom)
        .unwrap_or(S3_MAX_PARTS)
        .min(S3_MAX_PARTS)
}

/// `CompleteMultipartUpload` body. Parts must be ascending; `ETag`s are quoted.
fn complete_multipart_xml(parts: &[CompletedPart]) -> String {
    use std::fmt::Write as _;
    let mut xml = String::from("<CompleteMultipartUpload>");
    for part in parts {
        let etag = part.etag.trim_matches('"');
        let _ = write!(
            xml,
            "<Part><PartNumber>{}</PartNumber><ETag>\"{}\"</ETag></Part>",
            part.part_number, etag
        );
    }
    xml.push_str("</CompleteMultipartUpload>");
    xml
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn part_size_clamps_to_bounds() {
        assert_eq!(part_size_for_nar(0), MIN_PART_SIZE);
        assert_eq!(part_size_for_nar(1024), MIN_PART_SIZE);
        // ~6.9 GiB envoy-deps NAR that triggered the S3 400s: small parts.
        assert_eq!(part_size_for_nar(7_332_485_232), MIN_PART_SIZE);
        // Huge NAR pushes the part size up in 16 MiB steps, under the cap.
        let big = part_size_for_nar(200 * 1024 * 1024 * 1024);
        assert!(big > MIN_PART_SIZE && big <= MAX_PART_SIZE);
        assert_eq!(big % (16 * 1024 * 1024), 0);
        assert_eq!(part_size_for_nar(u64::MAX), MAX_PART_SIZE);
    }

    #[test]
    fn parses_copy_result() {
        let xml = r"<CopyObjectResult><LastModified>t</LastModified><ETag>&quot;abc&quot;</ETag></CopyObjectResult>";
        let result: CopyResult = quick_xml::de::from_str(xml).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(result.etag, "\"abc\"");
        assert!(quick_xml::de::from_str::<CopyResult>("<nope/>").is_err());
    }

    #[test]
    fn parses_error_response() {
        let xml = r"<Error><Code>AccessDenied</Code><Message>nope</Message></Error>";
        let error: S3ErrorResponse = quick_xml::de::from_str(xml).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(error.code, "AccessDenied");
        assert_eq!(error.message, "nope");
        // Copy results must not be mistaken for errors.
        assert!(
            quick_xml::de::from_str::<S3ErrorResponse>(
                r"<CopyPartResult><ETag>x</ETag></CopyPartResult>"
            )
            .is_err()
        );
    }

    #[test]
    fn completion_xml_is_sorted_and_quoted() {
        let xml = complete_multipart_xml(&[
            CompletedPart {
                part_number: 1,
                etag: "\"aaa\"".into(),
            },
            CompletedPart {
                part_number: 2,
                etag: "bbb".into(),
            },
        ]);
        assert_eq!(
            xml,
            "<CompleteMultipartUpload>\
             <Part><PartNumber>1</PartNumber><ETag>\"aaa\"</ETag></Part>\
             <Part><PartNumber>2</PartNumber><ETag>\"bbb\"</ETag></Part>\
             </CompleteMultipartUpload>"
        );
    }
}
