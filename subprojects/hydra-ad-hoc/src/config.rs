//! Command line and TOML configuration, following the shape of the
//! other Rust services (`hydra-ws`, `hydra-queue-runner`): the socket
//! to listen on comes from the command line, everything else from a
//! TOML file whose absence means "all defaults".

use std::path::PathBuf;

use clap::Parser;
use color_eyre::eyre;
use listenfd::ListenFd;
use tokio::net::UnixListener;

/// Where the nix daemon socket comes from.
#[derive(Debug, Clone)]
pub(crate) enum BindSocket {
    /// Create the socket file ourselves.
    Path(PathBuf),
    /// Take it from systemd socket activation (`--socket -`).
    ListenFd,
}

impl std::fmt::Display for BindSocket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Path(path) => write!(f, "unix:{}", path.display()),
            Self::ListenFd => write!(f, "listen-fd"),
        }
    }
}

impl std::str::FromStr for BindSocket {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(if s == "-" {
            Self::ListenFd
        } else {
            Self::Path(s.into())
        })
    }
}

/// Name we look for in `LISTEN_FDNAMES`; matches `FileDescriptorName=`
/// in the socket unit.
const FD_NAME: &str = "daemon";

impl BindSocket {
    /// The listener systemd handed us, found by name (or, without
    /// `LISTEN_FDNAMES`, by taking the first).
    pub(crate) fn inherited() -> eyre::Result<UnixListener> {
        let fd_names: Vec<String> = std::env::var("LISTEN_FDNAMES")
            .unwrap_or_default()
            .split(':')
            .map(String::from)
            .collect();
        let idx = fd_names.iter().position(|n| n == FD_NAME).unwrap_or(0);
        let mut listenfd = ListenFd::from_env();
        let std_listener = listenfd
            .take_unix_listener(idx)?
            .ok_or_else(|| eyre::eyre!("No listenfd unix listener at index {idx} for daemon"))?;
        std_listener.set_nonblocking(true)?;
        Ok(UnixListener::from_std(std_listener)?)
    }
}

#[derive(Parser, Debug)]
#[command(about = "Nix daemon proxy that turns build requests into ad-hoc Hydra builds")]
pub(crate) struct Cli {
    /// Unix socket to listen on for nix daemon connections, or `-` to
    /// inherit one from systemd socket activation.
    #[arg(short, long, default_value = "/tmp/hydra-ad-hoc.sock")]
    pub socket: BindSocket,

    /// Config path
    #[arg(short, long, default_value = "ad-hoc.toml")]
    pub config_path: String,
}

fn default_db_url() -> secrecy::SecretString {
    db::DEFAULT_LOCAL_URL.into()
}

const fn default_max_db_connections() -> u32 {
    4
}

fn default_upstream_socket() -> String {
    "/nix/var/nix/daemon-socket/socket".into()
}

fn default_store_dir() -> String {
    "/nix/store".into()
}

/// Main configuration of the application
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AppConfig {
    #[serde(default = "default_db_url")]
    db_url: secrecy::SecretString,

    #[serde(default = "default_max_db_connections")]
    max_db_connections: u32,

    /// Upstream nix daemon socket to proxy read operations to.
    #[serde(default = "default_upstream_socket")]
    upstream_socket: String,

    /// Nix store directory.
    #[serde(default = "default_store_dir")]
    store_dir: String,
}

impl From<AppConfig> for App {
    fn from(val: AppConfig) -> Self {
        Self {
            db_url: std::env::var(db::URL_ENV_VAR)
                .map(secrecy::SecretString::from)
                .unwrap_or(val.db_url),
            max_db_connections: val.max_db_connections,
            upstream_socket: val.upstream_socket,
            store_dir: val.store_dir,
        }
    }
}

#[derive(Debug)]
pub(crate) struct App {
    pub db_url: secrecy::SecretString,
    pub max_db_connections: u32,
    pub upstream_socket: String,
    pub store_dir: String,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConfigError {
    #[error("Failed to parse TOML from '{path}': {source}")]
    ParseToml {
        path: String,
        source: toml::de::Error,
    },

    #[error("Failed to parse default config: {0}")]
    ParseDefault(toml::de::Error),

    #[error("Failed to read config from '{path}': {source}")]
    Read {
        path: String,
        source: std::io::Error,
    },
}

impl App {
    #[tracing::instrument(err)]
    pub(crate) fn init(filepath: &str) -> Result<Self, ConfigError> {
        tracing::info!("Trying to load file: {filepath}");
        let toml: AppConfig = match fs_err::read_to_string(filepath) {
            Ok(content) => toml::from_str(&content).map_err(|e| ConfigError::ParseToml {
                path: filepath.to_string(),
                source: e,
            })?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::warn!("no config file found at '{filepath}'! Using default config");
                toml::from_str("").map_err(ConfigError::ParseDefault)?
            }
            Err(e) => {
                return Err(ConfigError::Read {
                    path: filepath.to_string(),
                    source: e,
                });
            }
        };
        tracing::info!("Loaded config: {toml:?}");
        Ok(toml.into())
    }
}
