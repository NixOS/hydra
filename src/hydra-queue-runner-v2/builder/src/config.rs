use clap::Parser;

#[derive(Parser, Debug)]
#[clap(
    author,
    version,
    about,
    long_about = None,
)]
pub struct Args {
    /// Gateway endpoint
    #[clap(short, long, default_value = "http://[::1]:50051")]
    pub gateway_endpoint: String,

    /// Ping interval in seconds
    #[clap(short, long, default_value_t = 10)]
    pub ping_interval: u64,

    /// Speed factor that is used when joining the queue-runner
    #[clap(short, long, default_value_t = 1.0)]
    pub speed_factor: f32,

    /// Maximum number of allowed jobs
    #[clap(long, default_value_t = 4)]
    pub max_jobs: u32,

    /// /tmp avail percentage Threshold
    #[clap(long, default_value_t = 10.)]
    pub tmp_avail_threshold: f32,

    /// prefix/store avail percentage Threshold
    #[clap(long, default_value_t = 10.)]
    pub store_avail_threshold: f32,

    /// Load1 Threshold
    #[clap(long, default_value_t = 8.)]
    pub load1_threshold: f32,

    /// CPU Pressure Threshold
    #[clap(long, default_value_t = 75.)]
    pub cpu_psi_threshold: f32,

    /// Memory Pressure Threshold
    #[clap(long, default_value_t = 80.)]
    pub mem_psi_threshold: f32,

    /// IO Pressure Threshold, null disables this pressure check
    #[clap(long)]
    pub io_psi_threshold: Option<f32>,

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

    /// List of supported systems, defaults to systems from nix and extra-platforms
    #[clap(long, default_value = None)]
    pub systems: Option<Vec<String>>,

    /// List of supported features, defaults to configured system features
    #[clap(long, default_value = None)]
    pub supported_features: Option<Vec<String>>,

    /// List of mandatory features
    #[clap(long, default_value = None)]
    pub mandatory_features: Option<Vec<String>>,

    /// Use substitution over pulling inputs via queue runner
    #[clap(long, default_value_t = false)]
    pub use_substitutes: bool,
}

impl Args {
    pub fn new() -> Self {
        Self::parse()
    }

    pub fn mtls_enabled(&self) -> bool {
        self.server_root_ca_cert_path.is_some()
            && self.client_cert_path.is_some()
            && self.client_key_path.is_some()
            && self.domain_name.is_some()
    }

    pub fn mtls_configured_correctly(&self) -> bool {
        self.mtls_enabled()
            || (self.server_root_ca_cert_path.is_none()
                && self.client_cert_path.is_none()
                && self.client_key_path.is_none()
                && self.domain_name.is_none())
    }

    pub async fn get_mtls(
        &self,
    ) -> anyhow::Result<(
        tonic::transport::Certificate,
        tonic::transport::Identity,
        String,
    )> {
        let server_root_ca_cert_path = self
            .server_root_ca_cert_path
            .as_deref()
            .ok_or(anyhow::anyhow!("server_root_ca_cert_path not provided"))?;
        let client_cert_path = self
            .client_cert_path
            .as_deref()
            .ok_or(anyhow::anyhow!("client_cert_path not provided"))?;
        let client_key_path = self
            .client_key_path
            .as_deref()
            .ok_or(anyhow::anyhow!("client_key_path not provided"))?;
        let domain_name = self
            .domain_name
            .as_deref()
            .ok_or(anyhow::anyhow!("domain_name not provided"))?;

        let server_root_ca_cert = tokio::fs::read_to_string(server_root_ca_cert_path).await?;
        let server_root_ca_cert = tonic::transport::Certificate::from_pem(server_root_ca_cert);

        let client_cert = tokio::fs::read_to_string(client_cert_path).await?;
        let client_key = tokio::fs::read_to_string(client_key_path).await?;
        let client_identity = tonic::transport::Identity::from_pem(client_cert, client_key);

        Ok((server_root_ca_cert, client_identity, domain_name.to_owned()))
    }
}
