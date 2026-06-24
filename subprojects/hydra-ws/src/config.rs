use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::task::{Context, Poll};

use clap::Parser;
use listenfd::ListenFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};

#[derive(Debug, Clone)]
pub enum BindSocket {
    Tcp(SocketAddr),
    Unix(PathBuf),
    ListenFd,
}

impl std::fmt::Display for BindSocket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Tcp(addr) => write!(f, "{addr}"),
            Self::Unix(path) => write!(f, "unix:{}", path.display()),
            Self::ListenFd => write!(f, "listen-fd"),
        }
    }
}

impl std::str::FromStr for BindSocket {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.parse::<SocketAddr>().map(Self::Tcp).or_else(|_| {
            if s == "-" {
                Ok(Self::ListenFd)
            } else {
                Ok(Self::Unix(s.into()))
            }
        })
    }
}

impl BindSocket {
    pub async fn bind(&self) -> std::io::Result<Listener> {
        match self {
            Self::Tcp(addr) => {
                let listener = TcpListener::bind(addr).await?;
                Ok(Listener::Tcp(listener))
            }
            Self::Unix(path) => {
                let _ = fs_err::remove_file(path);
                let listener = UnixListener::bind(path)?;
                Ok(Listener::Unix(listener))
            }
            Self::ListenFd => {
                let mut listenfd = ListenFd::from_env();
                let std_listener = listenfd.take_tcp_listener(0)?.ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::NotFound, "no inherited fd")
                })?;
                std_listener.set_nonblocking(true)?;
                let listener = TcpListener::from_std(std_listener)?;
                Ok(Listener::Tcp(listener))
            }
        }
    }
}

#[derive(Debug)]
pub enum Listener {
    Tcp(TcpListener),
    Unix(UnixListener),
}

impl Listener {
    pub async fn accept(&self) -> std::io::Result<(Stream, SocketAddr)> {
        match self {
            Self::Tcp(l) => {
                let (stream, addr) = l.accept().await?;
                Ok((Stream::Tcp(stream), addr))
            }
            Self::Unix(l) => {
                let (stream, _) = l.accept().await?;
                let addr = SocketAddr::new(std::net::Ipv4Addr::UNSPECIFIED.into(), 0);
                Ok((Stream::Unix(stream), addr))
            }
        }
    }
}

#[derive(Debug)]
pub enum Stream {
    Tcp(TcpStream),
    Unix(UnixStream),
}

impl AsyncRead for Stream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(s) => Pin::new(s).poll_read(cx, buf),
            Self::Unix(s) => Pin::new(s).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Self::Tcp(s) => Pin::new(s).poll_write(cx, buf),
            Self::Unix(s) => Pin::new(s).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(s) => Pin::new(s).poll_flush(cx),
            Self::Unix(s) => Pin::new(s).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(s) => Pin::new(s).poll_shutdown(cx),
            Self::Unix(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}

#[derive(Parser, Debug)]
#[clap(
    author,
    version,
    about,
    long_about = None,
)]
pub struct Cli {
    /// Address to bind the WebSocket server
    #[arg(short, long, default_value = "[::1]:9283")]
    pub bind: BindSocket,

    /// Config path
    #[clap(short, long, default_value = "ws-config.toml")]
    pub config_path: String,
}

impl Default for Cli {
    fn default() -> Self {
        Self::new()
    }
}

impl Cli {
    #[must_use]
    pub fn new() -> Self {
        Self::parse()
    }
}

fn default_pg_socket_url() -> secrecy::SecretString {
    "postgres://hydra@%2Frun%2Fpostgresql:5432/hydra".into()
}

const fn default_max_db_connections() -> u32 {
    128
}

const fn default_idle_grace() -> u64 {
    128
}

fn default_data_dir() -> PathBuf {
    "/tmp/hydra".into()
}

/// Main configuration of the application
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    #[serde(default = "default_pg_socket_url")]
    db_url: secrecy::SecretString,

    #[serde(default = "default_max_db_connections")]
    max_db_connections: u32,

    #[serde(default = "default_idle_grace")]
    idle_grace: u64,

    #[serde(default = "default_data_dir")]
    hydra_data_dir: PathBuf,
}

impl From<AppConfig> for App {
    fn from(val: AppConfig) -> Self {
        let hydra_log_dir = val.hydra_data_dir.join("build-logs");
        Self {
            db_url: std::env::var("HYDRA_DATABASE_URL")
                .map(secrecy::SecretString::from)
                .unwrap_or(val.db_url),
            max_db_connections: val.max_db_connections,
            idle_grace: val.idle_grace,
            log_prefix: hydra_log_dir,
        }
    }
}

#[derive(Debug)]
pub struct App {
    pub db_url: secrecy::SecretString,
    pub max_db_connections: u32,
    pub idle_grace: u64,
    pub log_prefix: PathBuf,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("Failed to parse TOML from '{path}': {source}")]
    ParseToml {
        path: String,
        source: toml::de::Error,
    },

    #[error("Failed to parse default config: {0}")]
    ParseDefault(toml::de::Error),
}

impl App {
    #[tracing::instrument(err)]
    pub fn init(filepath: &str) -> Result<Self, ConfigError> {
        tracing::info!("Trying to load file: {filepath}");
        let toml: AppConfig = if let Ok(content) = fs_err::read_to_string(filepath) {
            toml::from_str(&content).map_err(|e| ConfigError::ParseToml {
                path: filepath.to_string(),
                source: e,
            })?
        } else {
            tracing::warn!("no config file found! Using default config");
            toml::from_str("").map_err(ConfigError::ParseDefault)?
        };
        tracing::info!("Loaded config: {toml:?}");
        Ok(toml.into())
    }
}
