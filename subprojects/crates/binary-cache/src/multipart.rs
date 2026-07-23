//! Presigned S3 multipart uploads.
//!
//! `object_store`'s signer only presigns a single `PUT`, capping uploads at
//! S3's 5 GiB single-object limit. For larger NARs the server presigns the S3
//! multipart `UploadPart` operations with `aws-sigv4` so the builder can PUT
//! the parts directly to S3. `CreateMultipartUpload`, `CompleteMultipartUpload`
//! and `AbortMultipartUpload` stay server-side (signed and executed here): the
//! builder only ever holds part URLs and reports the resulting `ETag`s back for
//! completion.

use std::future::Future;
use std::pin::Pin;
use std::time::{Duration, SystemTime};

use aws_credential_types::Credentials;
use aws_sigv4::http_request::{
    PayloadChecksumKind, SignableBody, SignableRequest, SignatureLocation, SigningParams,
    SigningSettings, sign,
};
use aws_sigv4::sign::v4;
use aws_smithy_runtime_api::client::identity::Identity;
use secrecy::ExposeSecret as _;

use crate::CacheError;
use crate::cfg::{S3ClientConfig, S3Scheme};

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

/// Presigns and drives S3 multipart operations for a configured bucket using
/// static credentials. Mirrors the URL/credential handling of the
/// `object_store` client in [`crate::S3BinaryCacheClient`] so presigned part
/// PUTs and the server-side create/complete/abort requests hit the same URL.
#[derive(Debug, Clone)]
pub struct MultipartPresigner {
    credentials: Credentials,
    region: String,
    scheme: S3Scheme,
    /// Host portion of the endpoint, e.g. `s3.us-east-1.amazonaws.com`.
    host: String,
    bucket: String,
    http_client: reqwest::Client,
}

impl MultipartPresigner {
    /// Build a presigner from the cache's S3 client config. Errors if no static
    /// credentials are available, since presigning requires them.
    pub fn from_config(cfg: &S3ClientConfig) -> Result<Self, CacheError> {
        let (access_key_id, secret_access_key) = resolve_static_credentials(cfg)?;
        let credentials = Credentials::new(
            access_key_id,
            secret_access_key.expose_secret().to_owned(),
            None,
            None,
            "binary-cache",
        );

        let host = match &cfg.endpoint {
            Some(endpoint) => endpoint
                .rsplit("://")
                .next()
                .unwrap_or(endpoint)
                .trim_end_matches('/')
                .to_owned(),
            None => format!("s3.{}.amazonaws.com", cfg.region),
        };

        Ok(Self {
            credentials,
            region: cfg.region.clone(),
            scheme: cfg.scheme,
            host,
            bucket: cfg.bucket.clone(),
            http_client: reqwest::Client::new(),
        })
    }

    fn scheme_str(&self) -> &'static str {
        match self.scheme {
            S3Scheme::HTTP => "http",
            S3Scheme::HTTPS => "https",
        }
    }

    // Path-style so presigned and object_store requests hit the same URL.
    fn object_url(&self, key: &str) -> String {
        format!(
            "{}://{}/{}/{}",
            self.scheme_str(),
            self.host,
            self.bucket,
            key
        )
    }

    fn signing_params<'a>(
        &'a self,
        identity: &'a Identity,
        settings: SigningSettings,
        url: &str,
    ) -> Result<SigningParams<'a>, CacheError> {
        Ok(v4::SigningParams::builder()
            .identity(identity)
            .region(&self.region)
            .name("s3")
            .time(SystemTime::now())
            .settings(settings)
            .build()
            .map_err(|e| presign_err(url, e))?
            .into())
    }

    // Returns (URL to sign, URL to send): raw query values for aws-sigv4 to
    // encode, and the same encoding applied ourselves, so the two match.
    fn query_urls(&self, key: &str, query: &[(&str, &str)]) -> (String, String) {
        let object_url = self.object_url(key);
        if query.is_empty() {
            return (object_url.clone(), object_url);
        }
        let join = |encode: bool| {
            query
                .iter()
                .map(|(k, v)| {
                    if encode {
                        format!("{k}={}", sigv4_encode(v))
                    } else {
                        format!("{k}={v}")
                    }
                })
                .collect::<Vec<_>>()
                .join("&")
        };
        (
            format!("{object_url}?{}", join(false)),
            format!("{object_url}?{}", join(true)),
        )
    }

    // Payload is signed as UNSIGNED-PAYLOAD so bodies can stream / be omitted.
    fn presign(
        &self,
        method: &str,
        url: &str,
        query: &[(&str, &str)],
        expires: Duration,
    ) -> Result<String, CacheError> {
        let mut settings = SigningSettings::default();
        settings.signature_location = SignatureLocation::QueryParams;
        settings.expires_in = Some(expires);

        let identity: Identity = self.credentials.clone().into();
        let signing_params = self.signing_params(&identity, settings, url)?;

        // Sign with raw operation values; aws-sigv4 percent-encodes them for the
        // canonical request exactly as we do when building the final URL below.
        let full_url = if query.is_empty() {
            url.to_owned()
        } else {
            let qs = query
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join("&");
            format!("{url}?{qs}")
        };

        let (instructions, _signature) =
            sign(signable_request(method, &full_url)?, &signing_params)
                .map_err(|e| presign_err(url, e))?
                .into_parts();
        let (_headers, auth_params) = instructions.into_parts();

        // Assemble the query ourselves with SigV4 percent-encoding. Routing
        // through `url`'s form-encoding would turn a `+` in an S3 uploadId into
        // a space, breaking the signature.
        let pairs = query
            .iter()
            .map(|(name, value)| format!("{name}={}", sigv4_encode(value)))
            .chain(
                auth_params
                    .iter()
                    .map(|(name, value)| format!("{name}={}", sigv4_encode(value.as_ref()))),
            )
            .collect::<Vec<_>>()
            .join("&");
        Ok(format!("{url}?{pairs}"))
    }

    /// Bucket this presigner writes to.
    #[must_use]
    pub fn bucket(&self) -> &str {
        &self.bucket
    }

    /// Whether one signed request can address both buckets,
    /// i.e. a server-side copy from `source` into this bucket is possible.
    #[must_use]
    pub fn same_endpoint(&self, source: &Self) -> bool {
        self.host == source.host && self.scheme == source.scheme
    }

    /// Sign a request with header-based `SigV4` auth for the queue runner executes itself.
    /// Returns extra plus signing headers to apply.
    fn sign_headers(
        &self,
        method: &str,
        url: &str,
        extra_headers: &[(&str, String)],
    ) -> Result<Vec<(String, String)>, CacheError> {
        let mut settings = SigningSettings::default();
        // S3 requires the payload checksum header for header-auth requests.
        settings.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;

        let identity: Identity = self.credentials.clone().into();
        let signing_params = self.signing_params(&identity, settings, url)?;

        let signable = SignableRequest::new(
            method,
            url,
            extra_headers.iter().map(|(k, v)| (*k, v.as_str())),
            SignableBody::UnsignedPayload,
        )
        .map_err(|e| presign_err(url, e))?;
        let (instructions, _signature) = sign(signable, &signing_params)
            .map_err(|e| presign_err(url, e))?
            .into_parts();
        let (signed, _params) = instructions.into_parts();

        Ok(extra_headers
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .chain(
                signed
                    .into_iter()
                    .map(|h| (h.name().to_owned(), h.value().to_owned())),
            )
            .collect())
    }

    /// Send a directly signed, empty-body S3 request and return the response body.
    async fn send_signed(
        &self,
        method: reqwest::Method,
        key: &str,
        query: &[(&str, &str)],
        extra_headers: &[(&str, String)],
    ) -> Result<String, CacheError> {
        let (url_for_signing, url_to_send) = self.query_urls(key, query);
        let headers = self.sign_headers(method.as_str(), &url_for_signing, extra_headers)?;
        let mut request = self.http_client.request(method, &url_to_send);
        for (name, value) in headers {
            request = request.header(name, value);
        }
        let body = request
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
    #[tracing::instrument(skip(self, content_type, content_encoding), err)]
    pub async fn copy_object_from(
        &self,
        source_bucket: &str,
        key: &str,
        size: u64,
        content_type: &str,
        content_encoding: &str,
    ) -> Result<(), CacheError> {
        let copy_source = format!("/{source_bucket}/{key}");

        if size <= MAX_COPY_OBJECT_SIZE {
            self.send_signed(
                reqwest::Method::PUT,
                key,
                &[],
                &[("x-amz-copy-source", copy_source)],
            )
            .await?;
            return Ok(());
        }

        let upload_id = self
            .initiate_upload(key, content_type, content_encoding)
            .await?;
        let mut parts = Vec::new();
        let mut start = 0u64;
        let mut part_number = 1u32;
        while start < size {
            let end = start.saturating_add(COPY_PART_SIZE).min(size) - 1;
            let part_number_str = part_number.to_string();
            let body = self
                .send_signed(
                    reqwest::Method::PUT,
                    key,
                    &[
                        ("partNumber", part_number_str.as_str()),
                        ("uploadId", upload_id.as_str()),
                    ],
                    &[
                        ("x-amz-copy-source", copy_source.clone()),
                        ("x-amz-copy-source-range", format!("bytes={start}-{end}")),
                    ],
                )
                .await?;
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
    pub async fn create(
        &self,
        key: &str,
        content_type: &str,
        content_encoding: &str,
        nar_size: u64,
        expires: Duration,
    ) -> Result<PresignedMultipart, CacheError> {
        let upload_id = self
            .initiate_upload(key, content_type, content_encoding)
            .await?;

        let part_size = part_size_for_nar(nar_size);
        let part_count = estimated_part_count(nar_size, part_size);
        let parts = self.presign_parts(key, &upload_id, 1..=part_count, expires)?;

        Ok(PresignedMultipart {
            key: key.to_owned(),
            upload_id,
            part_size,
            parts,
        })
    }

    /// Presign additional `UploadPart` URLs for an in-progress upload.
    pub fn presign_parts(
        &self,
        key: &str,
        upload_id: &str,
        part_numbers: std::ops::RangeInclusive<u32>,
        expires: Duration,
    ) -> Result<Vec<PresignedPart>, CacheError> {
        let object_url = self.object_url(key);
        part_numbers
            .map(|part_number| {
                let url = self.presign(
                    "PUT",
                    &object_url,
                    &[
                        ("partNumber", &part_number.to_string()),
                        ("uploadId", upload_id),
                    ],
                    expires,
                )?;
                Ok(PresignedPart { part_number, url })
            })
            .collect()
    }

    /// Finalise the upload from the builder-reported part `ETag`s, sent with
    /// `If-None-Match: *` so `nar/<hash>` is write-once and never overwritten
    /// with a different compression (which would diverge from Fastly's cached
    /// copy). A 412 means another upload already stored a valid compression, so
    /// it counts as success: the object decompresses to the same `NarHash`.
    #[tracing::instrument(skip(self, parts), err)]
    pub async fn complete(
        &self,
        key: &str,
        upload_id: &str,
        mut parts: Vec<CompletedPart>,
    ) -> Result<WriteOutcome, CacheError> {
        parts.sort_by_key(|p| p.part_number);
        let body = complete_multipart_xml(&parts);

        let url = self.signed_object_request("POST", key, upload_id)?;
        let response = self
            .http_client
            .post(&url)
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

    fn signed_object_request(
        &self,
        method: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<String, CacheError> {
        self.presign(
            method,
            &self.object_url(key),
            &[("uploadId", upload_id)],
            Duration::from_mins(15),
        )
    }

    /// Execute `CreateMultipartUpload` and return the `UploadId`.
    async fn initiate_upload(
        &self,
        key: &str,
        content_type: &str,
        content_encoding: &str,
    ) -> Result<String, CacheError> {
        let url = self.presign(
            "POST",
            &self.object_url(key),
            &[("uploads", "")],
            Duration::from_mins(15),
        )?;

        let mut request = self
            .http_client
            .post(&url)
            .header("Content-Type", content_type);
        if !content_encoding.is_empty() {
            request = request.header("Content-Encoding", content_encoding);
        }

        let body = request
            .send()
            .await
            .map_err(|e| presign_err(key, e))?
            .error_for_status()
            .map_err(|e| presign_err(key, e))?
            .text()
            .await
            .map_err(|e| presign_err(key, e))?;

        let result: InitiateMultipartUploadResult =
            quick_xml::de::from_str(&body).map_err(|e| CacheError::PresignedUrlError {
                path: key.to_owned(),
                reason: format!("invalid CreateMultipartUpload response: {e}"),
            })?;
        Ok(result.upload_id)
    }
}

/// `CreateMultipartUpload` response body.
#[derive(Debug, serde::Deserialize)]
struct InitiateMultipartUploadResult {
    #[serde(rename = "UploadId")]
    upload_id: String,
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

fn signable_request<'a>(method: &'a str, url: &'a str) -> Result<SignableRequest<'a>, CacheError> {
    SignableRequest::new(
        method,
        url,
        std::iter::empty(),
        SignableBody::UnsignedPayload,
    )
    .map_err(|e| presign_err(url, e))
}

/// Percent-encode a query value per `SigV4`: everything except the unreserved
/// set `A-Za-z0-9-_.~`.
fn sigv4_encode(value: &str) -> std::borrow::Cow<'_, str> {
    const UNRESERVED: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~');
    percent_encoding::utf8_percent_encode(value, UNRESERVED).into()
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

fn resolve_static_credentials(
    cfg: &S3ClientConfig,
) -> Result<(String, secrecy::SecretString), CacheError> {
    if let Some(credentials) = &cfg.credentials {
        return Ok((
            credentials.access_key_id.clone(),
            credentials.secret_access_key.clone(),
        ));
    }
    if let (Ok(access_key_id), Ok(secret)) = (
        std::env::var("AWS_ACCESS_KEY_ID"),
        std::env::var("AWS_SECRET_ACCESS_KEY"),
    ) {
        return Ok((access_key_id, secret.into()));
    }
    let profile = cfg.profile.as_deref().unwrap_or("default");
    crate::cfg::read_aws_credentials_file(profile).map_err(|e| CacheError::ConfigurationError {
        message: format!("no static S3 credentials for presigned multipart uploads: {e}"),
    })
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
    fn sigv4_encode_matches_unreserved_set() {
        // The chars that broke url form-encoding must be percent-encoded.
        assert_eq!(sigv4_encode("ab+cd/ef=gh"), "ab%2Bcd%2Fef%3Dgh");
        // Unreserved characters pass through untouched.
        assert_eq!(sigv4_encode("AZaz09-_.~"), "AZaz09-_.~");
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
    fn parses_upload_id() {
        let xml = r#"<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>abc123==</UploadId></InitiateMultipartUploadResult>"#;
        let result: InitiateMultipartUploadResult =
            quick_xml::de::from_str(xml).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(result.upload_id, "abc123==");
        assert!(quick_xml::de::from_str::<InitiateMultipartUploadResult>("<nope/>").is_err());
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
