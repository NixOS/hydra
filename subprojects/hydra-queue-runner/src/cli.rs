//! Binary-only command-line parsing. This is the only module that depends
//! on `clap`; keeping it out of the library crate means the library (and
//! its examples) compile without argument parsing pulled in.

use std::net::SocketAddr;

use clap::Parser;

use crate::config::MtlsConfig;

#[derive(Debug, Clone)]
pub enum BindSocket {
    Tcp(SocketAddr),
    Unix(std::path::PathBuf),
    ListenFd,
}

impl std::str::FromStr for BindSocket {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.parse::<SocketAddr>().map(BindSocket::Tcp).or_else(|_| {
            if s == "-" {
                Ok(Self::ListenFd)
            } else {
                Ok(Self::Unix(s.into()))
            }
        })
    }
}

#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
pub struct Cli {
    /// REST server bind, either a `SocketAddr` or `-` to use `ListenFD` (systemd socket activation)
    #[clap(short, long, default_value = "[::1]:8080")]
    pub rest_bind: BindSocket,

    /// GRPC server bind, either a `SocketAddr`, a Path for a Unix Socket or `-` to use `ListenFD` (systemd socket activation)
    #[clap(short, long, default_value = "[::1]:50051")]
    pub grpc_bind: BindSocket,

    /// Config path
    #[clap(short, long, default_value = "config.toml")]
    pub config_path: String,

    /// Path to Server cert
    #[clap(long)]
    pub server_cert_path: Option<std::path::PathBuf>,

    /// Path to Server key
    #[clap(long)]
    pub server_key_path: Option<std::path::PathBuf>,

    /// Path to Client ca cert
    #[clap(long)]
    pub client_ca_cert_path: Option<std::path::PathBuf>,

    /// Dangerous to disable this, this is only implemented so we can manually trigger only one build
    #[clap(long, default_value_t = false)]
    pub disable_queue_monitor_loop: bool,
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

    /// The mTLS material the library's gRPC server needs, lifted out of the
    /// parsed arguments.
    #[must_use]
    pub fn mtls(&self) -> MtlsConfig {
        MtlsConfig {
            server_cert_path: self.server_cert_path.clone(),
            server_key_path: self.server_key_path.clone(),
            client_ca_cert_path: self.client_ca_cert_path.clone(),
        }
    }
}
