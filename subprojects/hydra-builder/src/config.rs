use clap::Parser;

/// Errors from reading builder configuration (mTLS certs, etc.).
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("missing config option: {0}")]
    MissingOption(&'static str),

    #[error("Reading configuration file")]
    Reading(#[source] std::io::Error),

    #[error("{context}")]
    Toml {
        context: String,
        #[source]
        source: toml::de::Error,
    },

    #[error(
        "mTLS configured improperly, please pass all options: \
        server_root_ca_cert_path, client_cert_path, client_key_path and domain_name"
    )]
    MtlsIncomplete,
}

/// Hydra builder: connects to the queue runner and runs build jobs.
//
// `config_path` is meta-config: it only locates the TOML file holding the
// operational settings (`AppConfig`); it is not itself part of either
// config. The connection/security options live in the flattened `Cli`.
#[derive(Parser, Debug)]
#[clap(
    author,
    version,
    about,
    long_about = None,
)]
pub struct Args {
    /// Path to the TOML config file holding the reloadable builder settings
    #[clap(short, long, default_value = "config.toml")]
    pub config_path: String,

    #[clap(flatten)]
    pub cli: Cli,
}

/// Connection and security options passed on the command line.
#[derive(clap::Args, Debug)]
pub struct Cli {
    /// Gateway endpoint
    #[clap(short, long, default_value = "http://[::1]:50051")]
    pub gateway_endpoint: String,

    /// Path to Server root ca cert
    #[clap(long)]
    pub server_root_ca_cert_path: Option<std::path::PathBuf>,

    /// Path to Client cert
    #[clap(long)]
    pub client_cert_path: Option<std::path::PathBuf>,

    /// Path to Client key
    #[clap(long)]
    pub client_key_path: Option<std::path::PathBuf>,

    /// Domain name for mtls
    #[clap(long)]
    pub domain_name: Option<String>,

    /// File to Authorization token, can be use as an alternative to mTLS
    #[clap(long)]
    pub authorization_file: Option<std::path::PathBuf>,
}

const fn default_ping_interval() -> u64 {
    10
}
const fn default_speed_factor() -> f32 {
    1.0
}
const fn default_max_jobs() -> u32 {
    4
}
const fn default_build_dir_avail_threshold() -> f32 {
    10.0
}
const fn default_store_avail_threshold() -> f32 {
    10.0
}
const fn default_load1_threshold() -> f32 {
    8.0
}
const fn default_cpu_psi_threshold() -> f32 {
    75.0
}
const fn default_mem_psi_threshold() -> f32 {
    80.0
}

/// Reloadable builder settings read from the TOML config file. Connection
/// and security options (gateway endpoint, mTLS, auth token) stay on the
/// CLI; everything operational lives here. Empty `systems` /
/// `supported_features` fall back to values read from `nix show-config`.
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    /// Ping interval in seconds
    #[serde(default = "default_ping_interval")]
    pub ping_interval: u64,

    /// Speed factor that is used when joining the queue-runner
    #[serde(default = "default_speed_factor")]
    pub speed_factor: f32,

    /// Maximum number of allowed jobs
    #[serde(default = "default_max_jobs")]
    pub max_jobs: u32,

    /// build dir available storage percentage Threshold
    #[serde(default = "default_build_dir_avail_threshold")]
    pub build_dir_avail_threshold: f32,

    /// prefix/store available storage percentage Threshold
    #[serde(default = "default_store_avail_threshold")]
    pub store_avail_threshold: f32,

    /// Load1 Threshold
    #[serde(default = "default_load1_threshold")]
    pub load1_threshold: f32,

    /// CPU Pressure Threshold
    #[serde(default = "default_cpu_psi_threshold")]
    pub cpu_psi_threshold: f32,

    /// Memory Pressure Threshold
    #[serde(default = "default_mem_psi_threshold")]
    pub mem_psi_threshold: f32,

    /// IO Pressure Threshold, null disables this pressure check
    #[serde(default)]
    pub io_psi_threshold: Option<f32>,

    /// List of supported systems. `None` (absent) falls back to `system`
    /// and `extra-platforms` from nix; an explicit empty list means none.
    #[serde(default)]
    pub systems: Option<Vec<String>>,

    /// List of supported features. `None` (absent) falls back to the
    /// configured system features from nix; an explicit empty list means none.
    #[serde(default)]
    pub supported_features: Option<Vec<String>>,

    /// List of mandatory features
    #[serde(default)]
    pub mandatory_features: Vec<String>,

    /// Use substitution over pulling inputs via queue runner
    #[serde(default)]
    pub use_substitutes: bool,
}

/// Load the builder settings from `filepath`. A missing file yields the
/// default settings, mirroring the queue runner's behaviour.
#[tracing::instrument(err)]
pub fn load_config(filepath: &str) -> Result<AppConfig, ConfigError> {
    let content = match fs_err::read_to_string(filepath) {
        Ok(content) => content,
        Err(_) => {
            tracing::warn!("no config file found at {filepath}! Using default config");
            String::new()
        }
    };
    let config: AppConfig = toml::from_str(&content).map_err(|source| ConfigError::Toml {
        context: format!("loading config from '{filepath}'"),
        source,
    })?;
    tracing::info!("Loaded config: {config:?}");
    Ok(config)
}

impl Default for Args {
    fn default() -> Self {
        Self::new()
    }
}

impl Args {
    #[must_use]
    pub fn new() -> Self {
        Self::parse()
    }
}

impl Cli {
    #[must_use]
    pub const fn mtls_enabled(&self) -> bool {
        self.server_root_ca_cert_path.is_some()
            && self.client_cert_path.is_some()
            && self.client_key_path.is_some()
            && self.domain_name.is_some()
    }

    #[must_use]
    pub const fn mtls_configured_correctly(&self) -> bool {
        self.mtls_enabled()
            || (self.server_root_ca_cert_path.is_none()
                && self.client_cert_path.is_none()
                && self.client_key_path.is_none()
                && self.domain_name.is_none())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_mtls(
        &self,
    ) -> Result<
        (
            tonic::transport::Certificate,
            tonic::transport::Identity,
            String,
        ),
        ConfigError,
    > {
        let server_root_ca_cert_path = self
            .server_root_ca_cert_path
            .as_deref()
            .ok_or(ConfigError::MissingOption("server_root_ca_cert_path"))?;
        let client_cert_path = self
            .client_cert_path
            .as_deref()
            .ok_or(ConfigError::MissingOption("client_cert_path"))?;
        let client_key_path = self
            .client_key_path
            .as_deref()
            .ok_or(ConfigError::MissingOption("client_key_path"))?;
        let domain_name = self
            .domain_name
            .as_deref()
            .ok_or(ConfigError::MissingOption("domain_name"))?;

        let server_root_ca_cert = fs_err::tokio::read_to_string(server_root_ca_cert_path)
            .await
            .map_err(ConfigError::Reading)?;
        let server_root_ca_cert = tonic::transport::Certificate::from_pem(server_root_ca_cert);

        let client_cert = fs_err::tokio::read_to_string(client_cert_path)
            .await
            .map_err(ConfigError::Reading)?;
        let client_key = fs_err::tokio::read_to_string(client_key_path)
            .await
            .map_err(ConfigError::Reading)?;
        let client_identity = tonic::transport::Identity::from_pem(client_cert, client_key);

        Ok((server_root_ca_cert, client_identity, domain_name.to_owned()))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_authorization_token(&self) -> Result<Option<String>, ConfigError> {
        if let Some(path) = &self.authorization_file {
            Ok(Some(
                fs_err::tokio::read_to_string(path)
                    .await
                    .map_err(ConfigError::Reading)?
                    .trim()
                    .to_string(),
            ))
        } else {
            Ok(None)
        }
    }
}
