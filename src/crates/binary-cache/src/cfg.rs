use hashbrown::HashMap;
use smallvec::SmallVec;

use crate::Compression;

const MIN_PRESIGNED_URL_EXPIRY_SECS: u64 = 60;
const MAX_PRESIGNED_URL_EXPIRY_SECS: u64 = 24 * 60 * 60;

#[derive(Debug, Clone)]
#[allow(clippy::struct_excessive_bools)]
pub struct S3CacheConfig {
    pub client_config: S3ClientConfig,

    pub compression: Compression,
    pub write_nar_listing: bool,
    pub write_debug_info: bool,
    pub write_realisation: bool,
    pub secret_key_files: SmallVec<[std::path::PathBuf; 4]>,
    pub parallel_compression: bool,
    pub compression_level: Option<i32>,

    pub narinfo_compression: Compression,
    pub ls_compression: Compression,
    pub log_compression: Compression,
    pub buffer_size: usize,

    pub presigned_url_expiry: std::time::Duration,
}

impl S3CacheConfig {
    #[must_use]
    pub fn new(client_config: S3ClientConfig) -> Self {
        Self {
            client_config,
            compression: Compression::Xz,
            write_nar_listing: false,
            write_debug_info: false,
            write_realisation: false,
            secret_key_files: SmallVec::default(),
            parallel_compression: false,
            compression_level: Option::default(),
            narinfo_compression: Compression::None,
            ls_compression: Compression::None,
            log_compression: Compression::None,
            buffer_size: 8 * 1024 * 1024,
            presigned_url_expiry: std::time::Duration::from_secs(3600),
        }
    }

    #[must_use]
    pub const fn with_compression(mut self, compression: Option<Compression>) -> Self {
        if let Some(compression) = compression {
            self.compression = compression;
        }
        self
    }

    #[must_use]
    pub fn with_write_nar_listing(mut self, write_nar_listing: Option<&str>) -> Self {
        if let Some(write_nar_listing) = write_nar_listing {
            let s = write_nar_listing.trim().to_ascii_lowercase();
            self.write_nar_listing = s.as_str() == "1" || s.as_str() == "true";
        }
        self
    }

    #[must_use]
    pub fn with_write_debug_info(mut self, write_debug_info: Option<&str>) -> Self {
        if let Some(write_debug_info) = write_debug_info {
            let s = write_debug_info.trim().to_ascii_lowercase();
            self.write_debug_info = s.as_str() == "1" || s.as_str() == "true";
        }
        self
    }

    #[must_use]
    pub fn with_write_realisation(mut self, write_realisation: Option<&str>) -> Self {
        if let Some(write_realisation) = write_realisation {
            let s = write_realisation.trim().to_ascii_lowercase();
            self.write_realisation = s.as_str() == "1" || s.as_str() == "true";
        }
        self
    }

    #[must_use]
    pub fn add_secret_key_files(mut self, secret_keys: &[std::path::PathBuf]) -> Self {
        for sk in secret_keys {
            self.secret_key_files.push(sk.into());
        }
        self
    }

    #[must_use]
    pub fn with_parallel_compression(mut self, parallel_compression: Option<&str>) -> Self {
        if let Some(parallel_compression) = parallel_compression {
            let s = parallel_compression.trim().to_ascii_lowercase();
            self.parallel_compression = s.as_str() == "1" || s.as_str() == "true";
        }
        self
    }

    #[must_use]
    pub const fn with_compression_level(mut self, compression_level: Option<i32>) -> Self {
        if let Some(compression_level) = compression_level {
            self.compression_level = Some(compression_level);
        }
        self
    }

    #[must_use]
    pub const fn with_narinfo_compression(mut self, compression: Option<Compression>) -> Self {
        if let Some(compression) = compression {
            self.narinfo_compression = compression;
        }
        self
    }

    #[must_use]
    pub const fn with_ls_compression(mut self, compression: Option<Compression>) -> Self {
        if let Some(compression) = compression {
            self.ls_compression = compression;
        }
        self
    }

    #[must_use]
    pub const fn with_log_compression(mut self, compression: Option<Compression>) -> Self {
        if let Some(compression) = compression {
            self.log_compression = compression;
        }
        self
    }

    #[must_use]
    pub const fn with_buffer_size(mut self, buffer_size: Option<usize>) -> Self {
        if let Some(buffer_size) = buffer_size {
            self.buffer_size = buffer_size;
        }
        self
    }

    pub fn with_presigned_url_expiry(
        mut self,
        expiry_secs: Option<u64>,
    ) -> Result<Self, UrlParseError> {
        if let Some(expiry_secs) = expiry_secs {
            if !(MIN_PRESIGNED_URL_EXPIRY_SECS..=MAX_PRESIGNED_URL_EXPIRY_SECS)
                .contains(&expiry_secs)
            {
                return Err(UrlParseError::InvalidPresignedUrlExpiry(
                    expiry_secs,
                    MIN_PRESIGNED_URL_EXPIRY_SECS,
                    MAX_PRESIGNED_URL_EXPIRY_SECS,
                ));
            }
            self.presigned_url_expiry = std::time::Duration::from_secs(expiry_secs);
        }
        Ok(self)
    }

    pub(crate) const fn get_compression_level(&self) -> async_compression::Level {
        if let Some(l) = self.compression_level {
            async_compression::Level::Precise(l)
        } else {
            async_compression::Level::Default
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum UrlParseError {
    #[error("Uri parse error: {0}")]
    UriParseError(#[from] url::ParseError),
    #[error("Int parse error: {0}")]
    IntParseError(#[from] std::num::ParseIntError),
    #[error("Invalid S3Scheme: {0}")]
    S3SchemeParseError(String),
    #[error("Invalid Compression: {0}")]
    CompressionParseError(String),
    #[error("Bad schema: {0}")]
    BadSchema(String),
    #[error("Bucket not defined")]
    NoBucket,
    #[error("Invalid presigned URL expiry: {0}. Must be between {1} and {2} seconds")]
    InvalidPresignedUrlExpiry(u64, u64, u64),
}

impl std::str::FromStr for S3CacheConfig {
    type Err = UrlParseError;

    #[allow(clippy::too_many_lines)]
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let uri = url::Url::parse(&s.trim().to_ascii_lowercase())?;
        if uri.scheme() != "s3" {
            return Err(UrlParseError::BadSchema(uri.scheme().to_owned()));
        }
        let bucket = uri.authority();
        if bucket.is_empty() {
            return Err(UrlParseError::NoBucket);
        }
        let query = uri.query_pairs().into_owned().collect::<HashMap<_, _>>();
        let cfg = S3ClientConfig::new(bucket.to_owned())
            .with_region(query.get("region").map(std::string::String::as_str))
            .with_scheme(
                query
                    .get("scheme")
                    .map(|x| x.parse::<S3Scheme>())
                    .transpose()
                    .map_err(UrlParseError::S3SchemeParseError)?,
            )
            .with_endpoint(query.get("endpoint").map(std::string::String::as_str))
            .with_profile(query.get("profile").map(std::string::String::as_str));

        Self::new(cfg)
            .with_compression(
                query
                    .get("compression")
                    .map(|x| x.parse::<Compression>())
                    .transpose()
                    .map_err(UrlParseError::CompressionParseError)?,
            )
            .with_write_nar_listing(
                query
                    .get("write-nar-listing")
                    .map(std::string::String::as_str),
            )
            .with_write_debug_info(
                query
                    .get("write-debug-info")
                    .map(std::string::String::as_str),
            )
            .add_secret_key_files(
                &query
                    .get("secret-key")
                    .map(|s| if s.is_empty() { vec![] } else { vec![s.into()] })
                    .unwrap_or_default(),
            )
            .add_secret_key_files(
                &query
                    .get("secret-keys")
                    .map(|s| {
                        s.split(',')
                            .filter(|s| !s.is_empty())
                            .map(Into::into)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default(),
            )
            .with_parallel_compression(
                query
                    .get("parallel-compression")
                    .map(std::string::String::as_str),
            )
            .with_compression_level(
                query
                    .get("compression-level")
                    .map(|x| x.parse::<i32>())
                    .transpose()?,
            )
            .with_narinfo_compression(
                query
                    .get("narinfo-compression")
                    .map(|x| x.parse::<Compression>())
                    .transpose()
                    .map_err(UrlParseError::CompressionParseError)?,
            )
            .with_ls_compression(
                query
                    .get("ls-compression")
                    .map(|x| x.parse::<Compression>())
                    .transpose()
                    .map_err(UrlParseError::CompressionParseError)?,
            )
            .with_log_compression(
                query
                    .get("log-compression")
                    .map(|x| x.parse::<Compression>())
                    .transpose()
                    .map_err(UrlParseError::CompressionParseError)?,
            )
            .with_buffer_size(
                query
                    .get("buffer-size")
                    .map(|x| x.parse::<usize>())
                    .transpose()?,
            )
            .with_presigned_url_expiry(
                query
                    .get("presigned-url-expiry")
                    .map(|x| x.parse::<u64>())
                    .transpose()?,
            )
    }
}

#[derive(Debug, Clone, Default, Copy, PartialEq, Eq)]
pub enum S3Scheme {
    HTTP,
    #[default]
    HTTPS,
}

impl std::str::FromStr for S3Scheme {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "http" => Ok(Self::HTTP),
            "https" => Ok(Self::HTTPS),
            v => Err(v.to_owned()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct S3ClientConfig {
    pub region: String,
    pub scheme: S3Scheme,
    pub endpoint: Option<String>,
    pub bucket: String,
    pub profile: Option<String>,
    pub(crate) credentials: Option<S3CredentialsConfig>,
}

impl S3ClientConfig {
    #[must_use]
    pub fn new(bucket: String) -> Self {
        Self {
            region: "us-east-1".into(),
            scheme: S3Scheme::default(),
            endpoint: None,
            bucket,
            profile: None,
            credentials: None,
        }
    }

    #[must_use]
    pub fn with_region(mut self, region: Option<&str>) -> Self {
        if let Some(region) = region {
            self.region = region.into();
        }
        self
    }

    #[must_use]
    pub const fn with_scheme(mut self, scheme: Option<S3Scheme>) -> Self {
        if let Some(scheme) = scheme {
            self.scheme = scheme;
        }
        self
    }

    #[must_use]
    pub fn with_endpoint(mut self, endpoint: Option<&str>) -> Self {
        self.endpoint = endpoint.map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_profile(mut self, profile: Option<&str>) -> Self {
        self.profile = profile.map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_credentials(mut self, credentials: Option<S3CredentialsConfig>) -> Self {
        self.credentials = credentials;
        self
    }
}

#[derive(Debug, Clone)]
pub struct S3CredentialsConfig {
    pub access_key_id: String,
    pub secret_access_key: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigReadError {
    #[error("Env var not found: {0}")]
    EnvVarNotFound(#[from] std::env::VarError),
    #[error("Read error: {0}")]
    ReadError(String),
    #[error("Profile missing: {0}")]
    ProfileMissing(String),
    #[error("Value missing: {0}")]
    ValueMissing(&'static str),
}

pub fn read_aws_credentials_file(profile: &str) -> Result<(String, String), ConfigReadError> {
    let home_dir = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE"))?;
    let credentials_path = format!("{home_dir}/.aws/credentials");

    let mut config = configparser::ini::Ini::new();
    let config_map = config
        .load(&credentials_path)
        .map_err(ConfigReadError::ReadError)?;
    parse_aws_credentials_file(&config_map, profile)
}

fn parse_aws_credentials_file(
    config_map: &std::collections::HashMap<
        String,
        std::collections::HashMap<String, Option<String>>,
    >,
    profile: &str,
) -> Result<(String, String), ConfigReadError> {
    let profile_map = if let Some(profile_map) = config_map.get(profile) {
        profile_map
    } else if let Some(profile_map) = config_map.get(&format!("profile {profile}")) {
        profile_map
    } else {
        let mut r_section_map = None;
        for (section_name, section_map) in config_map {
            let trimmed_section = section_name.trim();
            if trimmed_section == profile || trimmed_section == format!("profile {profile}") {
                r_section_map = Some(section_map);
                break;
            }
        }
        if let Some(section_map) = r_section_map {
            section_map
        } else {
            return Err(ConfigReadError::ProfileMissing(profile.into()));
        }
    };

    let access_key = profile_map
        .get("aws_access_key_id")
        .and_then(ToOwned::to_owned)
        .ok_or(ConfigReadError::ValueMissing("aws_access_key_id"))?;
    let secret_key = profile_map
        .get("aws_secret_access_key")
        .and_then(ToOwned::to_owned)
        .ok_or(ConfigReadError::ValueMissing("aws_secret_access_key"))?;

    Ok((access_key, secret_key))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::{
        Compression, ConfigReadError, S3CacheConfig, S3ClientConfig, S3CredentialsConfig, S3Scheme,
        UrlParseError, parse_aws_credentials_file,
    };
    use std::str::FromStr as _;

    #[test]
    fn test_parsing_default_profile_works() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
# AWS credentials file format:
# ~/.aws/credentials
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[production]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY"
                    .into(),
            )
            .unwrap();

        let (access_key, secret_key) = parse_aws_credentials_file(&config_map, "default").unwrap();
        assert_eq!(access_key, "AKIAIOSFODNN7EXAMPLE");
        assert_eq!(secret_key, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    }

    #[test]
    fn test_parsing_profile_with_spaces_and_comments() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
# This is a comment
# AWS credentials file with various formatting
[default]
# Another comment before the key
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Profile with spaces in name
[profile test]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY

# Profile with extra whitespace
[   staging   ]
aws_access_key_id = AKIAI44QH8DHBSTAGING
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbSTAGINGKEY"
                    .into(),
            )
            .unwrap();

        println!(
            "Available profiles: {:?}",
            config_map.keys().collect::<Vec<_>>()
        );

        let (access_key, secret_key) = parse_aws_credentials_file(&config_map, "default").unwrap();
        assert_eq!(access_key, "AKIAIOSFODNN7EXAMPLE");
        assert_eq!(secret_key, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");

        let (access_key, secret_key) = parse_aws_credentials_file(&config_map, "test").unwrap();
        assert_eq!(access_key, "AKIAI44QH8DHBEXAMPLE");
        assert_eq!(secret_key, "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY");

        let (access_key, secret_key) = parse_aws_credentials_file(&config_map, "staging").unwrap();
        assert_eq!(access_key, "AKIAI44QH8DHBSTAGING");
        assert_eq!(secret_key, "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbSTAGINGKEY");
    }

    #[test]
    fn test_missing_profile_returns_error() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                    .into(),
            )
            .unwrap();

        let result = parse_aws_credentials_file(&config_map, "nonexistent");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ConfigReadError::ProfileMissing(_)
        ));
    }

    #[test]
    fn test_missing_access_key_returns_error() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
[default]
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                    .into(),
            )
            .unwrap();

        let result = parse_aws_credentials_file(&config_map, "default");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ConfigReadError::ValueMissing("aws_access_key_id")
        ));
    }

    #[test]
    fn test_missing_secret_key_returns_error() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
                    .into(),
            )
            .unwrap();

        let result = parse_aws_credentials_file(&config_map, "default");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ConfigReadError::ValueMissing("aws_secret_access_key")
        ));
    }

    #[test]
    fn test_empty_credentials_file_returns_error() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config.read(String::new()).unwrap();

        let result = parse_aws_credentials_file(&config_map, "default");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ConfigReadError::ProfileMissing(_)
        ));
    }

    #[test]
    fn test_profile_with_special_characters() {
        let mut config = configparser::ini::Ini::new();
        let config_map = config
            .read(
                r"
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[my-test_profile]
aws_access_key_id = AKIAI44QH8DHBTEST
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbTESTKEY

[profile_123]
aws_access_key_id = AKIAI44QH8DHB123
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvb123KEY"
                    .into(),
            )
            .unwrap();

        let (access_key, secret_key) =
            parse_aws_credentials_file(&config_map, "my-test_profile").unwrap();
        assert_eq!(access_key, "AKIAI44QH8DHBTEST");
        assert_eq!(secret_key, "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbTESTKEY");

        let (access_key, secret_key) =
            parse_aws_credentials_file(&config_map, "profile_123").unwrap();
        assert_eq!(access_key, "AKIAI44QH8DHB123");
        assert_eq!(secret_key, "je7MtGbClwBF/2Zp9Utk/h3yCo8nvb123KEY");
    }

    #[test]
    fn test_presigned_url_expiry_validation() {
        let valid_cases = vec!["60", "3600", "86400"]; // 1min, 1hr, 1day
        for expiry in valid_cases {
            let config_str = format!("s3://test-bucket?presigned-url-expiry={expiry}");
            let result = S3CacheConfig::from_str(&config_str);
            assert!(result.is_ok(), "Should accept expiry: {expiry}");
        }

        let invalid_cases = vec!["0", "30", "604801"]; // too small, too small, too large
        for expiry in invalid_cases {
            let config_str = format!("s3://test-bucket?presigned-url-expiry={expiry}");
            let result = S3CacheConfig::from_str(&config_str);
            assert!(result.is_err(), "Should reject expiry: {expiry}");
            if let Err(UrlParseError::InvalidPresignedUrlExpiry(value, min, max)) = result {
                assert_eq!(value, expiry.parse::<u64>().unwrap());
                assert_eq!(min, 60);
                assert_eq!(max, 86_400);
            } else {
                panic!("Expected InvalidPresignedUrlExpiry error");
            }
        }
    }

    #[test]
    fn test_s3_cache_config_new_default_values() {
        let client_config = S3ClientConfig::new("test-bucket".to_string());
        let config = S3CacheConfig::new(client_config);

        assert_eq!(config.compression, Compression::Xz);
        assert!(!config.write_nar_listing);
        assert!(!config.write_debug_info);
        assert!(!config.write_realisation);
        assert!(config.secret_key_files.is_empty());
        assert!(!config.parallel_compression);
        assert_eq!(config.compression_level, None);
        assert_eq!(config.narinfo_compression, Compression::None);
        assert_eq!(config.ls_compression, Compression::None);
        assert_eq!(config.log_compression, Compression::None);
        assert_eq!(config.buffer_size, 8 * 1024 * 1024);
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(3600)
        );
    }

    #[test]
    fn test_s3_cache_config_builder_methods() {
        let client_config = S3ClientConfig::new("test-bucket".to_string());

        let config =
            S3CacheConfig::new(client_config.clone()).with_compression(Some(Compression::Bzip2));
        assert_eq!(config.compression, Compression::Bzip2);

        let config = S3CacheConfig::new(client_config.clone()).with_compression(None);
        assert_eq!(config.compression, Compression::Xz);

        let config = S3CacheConfig::new(client_config.clone()).with_write_nar_listing(Some("true"));
        assert!(config.write_nar_listing);

        let config = S3CacheConfig::new(client_config.clone()).with_write_nar_listing(Some("1"));
        assert!(config.write_nar_listing);

        let config =
            S3CacheConfig::new(client_config.clone()).with_write_nar_listing(Some("false"));
        assert!(!config.write_nar_listing);

        let config = S3CacheConfig::new(client_config.clone()).with_write_nar_listing(Some("0"));
        assert!(!config.write_nar_listing);

        let config = S3CacheConfig::new(client_config.clone()).with_write_nar_listing(None);
        assert!(!config.write_nar_listing);

        let config = S3CacheConfig::new(client_config.clone()).with_write_debug_info(Some("TRUE"));
        assert!(config.write_debug_info);

        let config =
            S3CacheConfig::new(client_config.clone()).with_write_debug_info(Some("  True  "));
        assert!(config.write_debug_info);

        let config = S3CacheConfig::new(client_config.clone()).with_write_debug_info(None);
        assert!(!config.write_debug_info);

        let config = S3CacheConfig::new(client_config.clone()).with_write_realisation(Some("TRUE"));
        assert!(config.write_realisation);

        let config =
            S3CacheConfig::new(client_config.clone()).with_write_realisation(Some("  True  "));
        assert!(config.write_realisation);

        let config = S3CacheConfig::new(client_config.clone()).with_write_realisation(None);
        assert!(!config.write_realisation);

        let secret_keys = vec![
            std::path::PathBuf::from("/path/to/key1"),
            std::path::PathBuf::from("/path/to/key2"),
        ];
        let config = S3CacheConfig::new(client_config.clone()).add_secret_key_files(&secret_keys);
        assert_eq!(config.secret_key_files.len(), 2);
        assert_eq!(
            config.secret_key_files[0],
            std::path::PathBuf::from("/path/to/key1")
        );
        assert_eq!(
            config.secret_key_files[1],
            std::path::PathBuf::from("/path/to/key2")
        );

        let config = S3CacheConfig::new(client_config.clone()).with_parallel_compression(Some("1"));
        assert!(config.parallel_compression);

        let config =
            S3CacheConfig::new(client_config.clone()).with_parallel_compression(Some("false"));
        assert!(!config.parallel_compression);

        let config = S3CacheConfig::new(client_config.clone()).with_compression_level(Some(9));
        assert_eq!(config.compression_level, Some(9));
        assert!(matches!(
            config.get_compression_level(),
            async_compression::Level::Precise(9)
        ));

        let config = S3CacheConfig::new(client_config.clone()).with_compression_level(None);
        assert_eq!(config.compression_level, None);
        assert!(matches!(
            config.get_compression_level(),
            async_compression::Level::Default
        ));

        let config = S3CacheConfig::new(client_config.clone())
            .with_narinfo_compression(Some(Compression::Zstd));
        assert_eq!(config.narinfo_compression, Compression::Zstd);

        let config = S3CacheConfig::new(client_config.clone())
            .with_ls_compression(Some(Compression::Brotli));
        assert_eq!(config.ls_compression, Compression::Brotli);

        let config =
            S3CacheConfig::new(client_config.clone()).with_log_compression(Some(Compression::Xz));
        assert_eq!(config.log_compression, Compression::Xz);

        let config =
            S3CacheConfig::new(client_config.clone()).with_buffer_size(Some(16 * 1024 * 1024));
        assert_eq!(config.buffer_size, 16 * 1024 * 1024);

        let config = S3CacheConfig::new(client_config.clone())
            .with_presigned_url_expiry(Some(7200))
            .unwrap();
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(7200)
        );

        let config = S3CacheConfig::new(client_config)
            .with_presigned_url_expiry(None)
            .unwrap();
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(3600)
        );
    }

    #[test]
    fn test_s3_cache_config_from_str_basic() {
        let config = S3CacheConfig::from_str("s3://my-bucket").unwrap();
        assert_eq!(config.client_config.bucket, "my-bucket");
        assert_eq!(config.client_config.region, "us-east-1");
        assert_eq!(config.client_config.scheme, S3Scheme::HTTPS);
        assert!(config.client_config.endpoint.is_none());
        assert!(config.client_config.profile.is_none());
    }

    #[test]
    fn test_s3_cache_config_from_str_with_parameters() {
        let config_str = "s3://test-bucket?region=eu-west-1&scheme=http&endpoint=custom.example.com&profile=myprofile&compression=zstd&write-nar-listing=true&write-debug-info=1&parallel-compression=true&compression-level=9&narinfo-compression=bz2&ls-compression=br&log-compression=xz&buffer-size=16777216&presigned-url-expiry=7200";

        let config = S3CacheConfig::from_str(config_str).unwrap();

        assert_eq!(config.client_config.bucket, "test-bucket");
        assert_eq!(config.client_config.region, "eu-west-1");
        assert_eq!(config.client_config.scheme, S3Scheme::HTTP);
        assert_eq!(
            config.client_config.endpoint,
            Some("custom.example.com".to_string())
        );
        assert_eq!(config.client_config.profile, Some("myprofile".to_string()));
        assert_eq!(config.compression, Compression::Zstd);
        assert!(config.write_nar_listing);
        assert!(config.write_debug_info);
        assert!(config.parallel_compression);
        assert_eq!(config.compression_level, Some(9));
        assert_eq!(config.narinfo_compression, Compression::Bzip2);
        assert_eq!(config.ls_compression, Compression::Brotli);
        assert_eq!(config.log_compression, Compression::Xz);
        assert_eq!(config.buffer_size, 16_777_216);
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(7200)
        );
    }

    #[test]
    fn test_s3_cache_config_from_str_with_secret_keys() {
        let config_str = "s3://test-bucket?secret-key=/path/to/key1";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(config.secret_key_files.len(), 1);
        assert_eq!(
            config.secret_key_files[0],
            std::path::PathBuf::from("/path/to/key1")
        );

        let config_str = "s3://test-bucket?secret-keys=/path/to/key1,/path/to/key2,/path/to/key3";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(config.secret_key_files.len(), 3);
        assert_eq!(
            config.secret_key_files[0],
            std::path::PathBuf::from("/path/to/key1")
        );
        assert_eq!(
            config.secret_key_files[1],
            std::path::PathBuf::from("/path/to/key2")
        );
        assert_eq!(
            config.secret_key_files[2],
            std::path::PathBuf::from("/path/to/key3")
        );

        let config_str = "s3://test-bucket?secret-key=";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert!(config.secret_key_files.is_empty());

        let config_str = "s3://test-bucket?secret-keys=";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert!(config.secret_key_files.is_empty());

        let config_str = "s3://test-bucket?secret-keys=/path/to/key1,,/path/to/key3";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(config.secret_key_files.len(), 2);
        assert_eq!(
            config.secret_key_files[0],
            std::path::PathBuf::from("/path/to/key1")
        );
        assert_eq!(
            config.secret_key_files[1],
            std::path::PathBuf::from("/path/to/key3")
        );
    }

    #[test]
    fn test_s3_cache_config_from_str_case_insensitive() {
        let config_str =
            "s3://test-bucket?write-nar-listing=TRUE&write-debug-info=False&parallel-compression=1";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert!(config.write_nar_listing);
        assert!(!config.write_debug_info);
        assert!(config.parallel_compression);

        let config_str = "s3://test-bucket?compression=XZ&narinfo-compression=BZ2&ls-compression=BR&log-compression=ZSTD";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(config.compression, Compression::Xz);
        assert_eq!(config.narinfo_compression, Compression::Bzip2);
        assert_eq!(config.ls_compression, Compression::Brotli);
        assert_eq!(config.log_compression, Compression::Zstd);
    }

    #[test]
    fn test_s3_cache_config_from_str_errors() {
        let result = S3CacheConfig::from_str("http://test-bucket");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), UrlParseError::BadSchema(_)));

        let result = S3CacheConfig::from_str("s3://");
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), UrlParseError::NoBucket));

        let result = S3CacheConfig::from_str("s3://test-bucket?compression=invalid");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            UrlParseError::CompressionParseError(_)
        ));

        let result = S3CacheConfig::from_str("s3://test-bucket?scheme=invalid");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            UrlParseError::S3SchemeParseError(_)
        ));

        let result = S3CacheConfig::from_str("s3://test-bucket?compression-level=invalid");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            UrlParseError::IntParseError(_)
        ));

        let result = S3CacheConfig::from_str("s3://test-bucket?buffer-size=invalid");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            UrlParseError::IntParseError(_)
        ));

        let result = S3CacheConfig::from_str("s3://test-bucket?presigned-url-expiry=invalid");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            UrlParseError::IntParseError(_)
        ));
    }

    #[test]
    fn test_s3_scheme_from_str() {
        assert_eq!(S3Scheme::from_str("http").unwrap(), S3Scheme::HTTP);
        assert_eq!(S3Scheme::from_str("HTTP").unwrap(), S3Scheme::HTTP);
        assert_eq!(S3Scheme::from_str("Http").unwrap(), S3Scheme::HTTP);
        assert_eq!(S3Scheme::from_str("  http  ").unwrap(), S3Scheme::HTTP);

        assert_eq!(S3Scheme::from_str("https").unwrap(), S3Scheme::HTTPS);
        assert_eq!(S3Scheme::from_str("HTTPS").unwrap(), S3Scheme::HTTPS);
        assert_eq!(S3Scheme::from_str("Https").unwrap(), S3Scheme::HTTPS);
        assert_eq!(S3Scheme::from_str("  https  ").unwrap(), S3Scheme::HTTPS);

        assert!(S3Scheme::from_str("ftp").is_err());
        assert!(S3Scheme::from_str("").is_err());
        assert!(S3Scheme::from_str("invalid").is_err());
    }

    #[test]
    fn test_s3_client_config_builder() {
        let mut config = S3ClientConfig::new("test-bucket".to_string());

        assert_eq!(config.bucket, "test-bucket");
        assert_eq!(config.region, "us-east-1");
        assert_eq!(config.scheme, S3Scheme::HTTPS);
        assert!(config.endpoint.is_none());
        assert!(config.profile.is_none());
        assert!(config.credentials.is_none());

        config = config
            .with_region(Some("eu-west-1"))
            .with_scheme(Some(S3Scheme::HTTP))
            .with_endpoint(Some("custom.example.com"))
            .with_profile(Some("myprofile"))
            .with_credentials(Some(S3CredentialsConfig {
                access_key_id: "test-key".to_string(),
                secret_access_key: "test-secret".to_string(),
            }));

        assert_eq!(config.region, "eu-west-1");
        assert_eq!(config.scheme, S3Scheme::HTTP);
        assert_eq!(config.endpoint, Some("custom.example.com".to_string()));
        assert_eq!(config.profile, Some("myprofile".to_string()));
        assert!(config.credentials.is_some());

        let credentials = config.credentials.as_ref().unwrap();
        assert_eq!(credentials.access_key_id, "test-key");
        assert_eq!(credentials.secret_access_key, "test-secret");

        let config = config
            .with_region(None)
            .with_scheme(None)
            .with_endpoint(None)
            .with_profile(None)
            .with_credentials(None);

        assert_eq!(config.region, "eu-west-1");
        assert_eq!(config.scheme, S3Scheme::HTTP);
        assert_eq!(config.endpoint, None);
        assert_eq!(config.profile, None);
        assert!(config.credentials.is_none());
    }

    #[test]
    fn test_s3_client_config_new() {
        let config = S3ClientConfig::new("my-bucket".to_string());
        assert_eq!(config.bucket, "my-bucket");
        assert_eq!(config.region, "us-east-1");
        assert_eq!(config.scheme, S3Scheme::HTTPS);
        assert!(config.endpoint.is_none());
        assert!(config.profile.is_none());
        assert!(config.credentials.is_none());
    }

    #[test]
    fn test_s3_cache_config_chaining() {
        let client_config = S3ClientConfig::new("test-bucket".to_string());

        let config = S3CacheConfig::new(client_config)
            .with_compression(Some(Compression::Zstd))
            .with_write_nar_listing(Some("true"))
            .with_write_debug_info(Some("1"))
            .with_write_realisation(Some("1"))
            .with_parallel_compression(Some("true"))
            .with_compression_level(Some(6))
            .with_narinfo_compression(Some(Compression::Bzip2))
            .with_ls_compression(Some(Compression::Brotli))
            .with_log_compression(Some(Compression::Xz))
            .with_buffer_size(Some(16 * 1024 * 1024))
            .with_presigned_url_expiry(Some(7200))
            .unwrap()
            .add_secret_key_files(&[
                std::path::PathBuf::from("/path/to/key1"),
                std::path::PathBuf::from("/path/to/key2"),
            ]);

        assert_eq!(config.compression, Compression::Zstd);
        assert!(config.write_nar_listing);
        assert!(config.write_debug_info);
        assert!(config.write_realisation);
        assert!(config.parallel_compression);
        assert_eq!(config.compression_level, Some(6));
        assert_eq!(config.narinfo_compression, Compression::Bzip2);
        assert_eq!(config.ls_compression, Compression::Brotli);
        assert_eq!(config.log_compression, Compression::Xz);
        assert_eq!(config.buffer_size, 16 * 1024 * 1024);
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(7200)
        );
        assert_eq!(config.secret_key_files.len(), 2);
    }

    #[test]
    fn test_s3_cache_config_from_str_with_whitespace() {
        let config_str = "  s3://test-bucket?region=eu-west-1&compression=xz  ";
        let config = S3CacheConfig::from_str(config_str).unwrap();

        assert_eq!(config.client_config.bucket, "test-bucket");
        assert_eq!(config.client_config.region, "eu-west-1");
        assert_eq!(config.compression, Compression::Xz);
    }

    #[test]
    fn test_s3_cache_config_from_str_empty_query_params() {
        let config_str = "s3://test-bucket?";
        let config = S3CacheConfig::from_str(config_str).unwrap();

        assert_eq!(config.client_config.bucket, "test-bucket");
        assert_eq!(config.client_config.region, "us-east-1");
        assert_eq!(config.compression, Compression::Xz);
    }

    #[test]
    fn test_s3_cache_config_presigned_url_expiry_boundaries() {
        let config_str = "s3://test-bucket?presigned-url-expiry=60";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(60)
        );

        let config_str = "s3://test-bucket?presigned-url-expiry=86400";
        let config = S3CacheConfig::from_str(config_str).unwrap();
        assert_eq!(
            config.presigned_url_expiry,
            std::time::Duration::from_secs(86400)
        );

        let config_str = "s3://test-bucket?presigned-url-expiry=59";
        let result = S3CacheConfig::from_str(config_str);
        assert!(result.is_err());

        let config_str = "s3://test-bucket?presigned-url-expiry=86401";
        let result = S3CacheConfig::from_str(config_str);
        assert!(result.is_err());
    }
}
