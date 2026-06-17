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
    SignableBody, SignableRequest, SignatureLocation, SigningSettings, sign,
};
use aws_sigv4::sign::v4;
use secrecy::ExposeSecret as _;

use crate::CacheError;
use crate::cfg::{S3ClientConfig, S3Scheme};

/// NARs at or below this uncompressed size use a single presigned `PUT`; the
/// well-tested simple path is fine until the compressed object risks crossing
/// S3's 5 GiB single-`PUT` limit. Compression never grows an input by more
/// than a hair, so 4 GiB leaves ample margin below the limit.
pub const MULTIPART_THRESHOLD: u64 = 4 * 1024 * 1024 * 1024;

const MIN_PART_SIZE: u64 = 10 * 1024 * 1024;
const MAX_PART_SIZE: u64 = 5 * 1024 * 1024 * 1024;
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

        let identity: aws_smithy_runtime_api::client::identity::Identity =
            self.credentials.clone().into();
        let signing_params: aws_sigv4::http_request::SigningParams = v4::SigningParams::builder()
            .identity(&identity)
            .region(&self.region)
            .name("s3")
            .time(SystemTime::now())
            .settings(settings)
            .build()
            .map_err(|e| presign_err(url, e))?
            .into();

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

    /// Finalise the upload from the builder-reported part `ETag`s.
    #[tracing::instrument(skip(self, parts), err)]
    pub async fn complete(
        &self,
        key: &str,
        upload_id: &str,
        mut parts: Vec<CompletedPart>,
    ) -> Result<(), CacheError> {
        parts.sort_by_key(|p| p.part_number);
        let body = complete_multipart_xml(&parts);

        let url = self.signed_object_request("POST", key, upload_id)?;
        self.http_client
            .post(&url)
            .header("Content-Type", "application/xml")
            .body(body)
            .send()
            .await
            .map_err(|e| presign_err(key, e))?
            .error_for_status()
            .map_err(|e| presign_err(key, e))?;
        Ok(())
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

        extract_upload_id(&body).ok_or_else(|| CacheError::PresignedUrlError {
            path: key.to_owned(),
            reason: "CreateMultipartUpload response did not contain an UploadId".to_owned(),
        })
    }
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

/// Extract `<UploadId>` from the fixed-shape `CreateMultipartUpload` XML
/// response, avoiding an XML-parser dependency.
fn extract_upload_id(xml: &str) -> Option<String> {
    let start = xml.find("<UploadId>")? + "<UploadId>".len();
    let end = xml[start..].find("</UploadId>")? + start;
    Some(xml[start..end].to_owned())
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
    fn parses_upload_id() {
        let xml = r#"<?xml version="1.0"?><InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>abc123==</UploadId></InitiateMultipartUploadResult>"#;
        assert_eq!(extract_upload_id(xml).as_deref(), Some("abc123=="));
        assert_eq!(extract_upload_id("<nope/>"), None);
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
