use std::{net::SocketAddr, sync::Arc};

use anyhow::Context as _;
use clap::Parser;

#[derive(Debug, Clone)]
pub enum BindSocket {
    Tcp(SocketAddr),
    Unix(std::path::PathBuf),
    ListenFd,
}

impl std::str::FromStr for BindSocket {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.parse::<std::net::SocketAddr>()
            .map(BindSocket::Tcp)
            .or_else(|_| {
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
    /// Query the queue runner status
    #[clap(long)]
    pub status: bool,

    /// REST server bind
    #[clap(short, long, default_value = "[::1]:8080")]
    pub rest_bind: SocketAddr,

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

    #[must_use]
    pub const fn mtls_enabled(&self) -> bool {
        self.server_cert_path.is_some()
            && self.server_key_path.is_some()
            && self.client_ca_cert_path.is_some()
    }

    #[must_use]
    pub const fn mtls_configured_correctly(&self) -> bool {
        self.mtls_enabled()
            || (self.server_cert_path.is_none()
                && self.server_key_path.is_none()
                && self.client_ca_cert_path.is_none())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_mtls(
        &self,
    ) -> anyhow::Result<(tonic::transport::Certificate, tonic::transport::Identity)> {
        let server_cert_path = self
            .server_cert_path
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("server_cert_path not provided"))?;
        let server_key_path = self
            .server_key_path
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("server_key_path not provided"))?;

        let client_ca_cert_path = self
            .client_ca_cert_path
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("client_ca_cert_path not provided"))?;
        let client_ca_cert = fs_err::tokio::read_to_string(client_ca_cert_path).await?;
        let client_ca_cert = tonic::transport::Certificate::from_pem(client_ca_cert);

        let server_cert = fs_err::tokio::read_to_string(server_cert_path).await?;
        let server_key = fs_err::tokio::read_to_string(server_key_path).await?;
        let server_identity = tonic::transport::Identity::from_pem(server_cert, server_key);
        Ok((client_ca_cert, server_identity))
    }
}

fn default_data_dir() -> std::path::PathBuf {
    "/tmp/hydra".into()
}

fn default_pg_socket_url() -> secrecy::SecretString {
    "postgres://hydra@%2Frun%2Fpostgresql:5432/hydra".into()
}

const fn default_max_db_connections() -> u32 {
    128
}

const fn default_dispatch_trigger_timer_in_s() -> i64 {
    120
}

const fn default_queue_trigger_timer_in_s() -> i64 {
    -1
}

const fn default_max_tries() -> u32 {
    5
}

const fn default_retry_interval() -> u32 {
    60
}

const fn default_retry_backoff() -> f32 {
    3.0
}

const fn default_max_unsupported_time_in_s() -> i64 {
    120
}

const fn default_stop_queue_run_after_in_s() -> i64 {
    60
}

const fn default_max_concurrent_downloads() -> u32 {
    5
}

const fn default_concurrent_upload_limit() -> usize {
    5
}

const fn default_enable_fod_checker() -> bool {
    false
}

#[derive(Debug, Default, serde::Deserialize, Copy, Clone, PartialEq, Eq)]
pub enum MachineSortFn {
    SpeedFactorOnly,
    CpuCoreCountWithSpeedFactor,
    #[default]
    BogomipsWithSpeedFactor,
}

#[derive(Debug, Default, serde::Deserialize, Copy, Clone, PartialEq, Eq)]
pub enum MachineFreeFn {
    Dynamic,
    DynamicWithMaxJobLimit,
    #[default]
    Static,
}

#[derive(Debug, Default, serde::Deserialize, Copy, Clone, PartialEq, Eq)]
pub enum StepSortFn {
    Legacy,
    #[default]
    WithRdeps,
}

/// Main configuration of the application
#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "camelCase")]
struct AppConfig {
    #[serde(default = "default_data_dir")]
    hydra_data_dir: std::path::PathBuf,

    #[serde(default = "default_pg_socket_url")]
    db_url: secrecy::SecretString,

    #[serde(default = "default_max_db_connections")]
    max_db_connections: u32,

    #[serde(default)]
    machine_sort_fn: MachineSortFn,

    #[serde(default)]
    machine_free_fn: MachineFreeFn,

    #[serde(default)]
    step_sort_fn: StepSortFn,

    // setting this to -1, will disable the timer
    #[serde(default = "default_dispatch_trigger_timer_in_s")]
    dispatch_trigger_timer_in_s: i64,

    // setting this to -1, will disable the timer
    #[serde(default = "default_queue_trigger_timer_in_s")]
    queue_trigger_timer_in_s: i64,

    #[serde(default)]
    remote_store_addr: Vec<String>,

    #[serde(default)]
    use_substitutes: bool,

    roots_dir: Option<std::path::PathBuf>,

    #[serde(default = "default_max_tries")]
    max_retries: u32,

    #[serde(default = "default_retry_interval")]
    retry_interval: u32,

    #[serde(default = "default_retry_backoff")]
    retry_backoff: f32,

    #[serde(default = "default_max_unsupported_time_in_s")]
    max_unsupported_time_in_s: i64,

    #[serde(default = "default_stop_queue_run_after_in_s")]
    stop_queue_run_after_in_s: i64,

    #[serde(default = "default_max_concurrent_downloads")]
    max_concurrent_downloads: u32,

    #[serde(default = "default_concurrent_upload_limit")]
    concurrent_upload_limit: usize,

    token_list_path: Option<std::path::PathBuf>,

    #[serde(default = "default_enable_fod_checker")]
    enable_fod_checker: bool,

    #[serde(default)]
    use_presigned_uploads: bool,

    #[serde(default)]
    forced_substituters: Vec<String>,
}

/// Prepared configuration of the application
#[derive(Debug)]
pub struct PreparedApp {
    #[allow(dead_code)]
    hydra_data_dir: std::path::PathBuf,
    hydra_log_dir: std::path::PathBuf,
    lockfile: std::path::PathBuf,
    pub db_url: secrecy::SecretString,
    max_db_connections: u32,
    pub machine_sort_fn: MachineSortFn,
    machine_free_fn: MachineFreeFn,
    pub step_sort_fn: StepSortFn,
    dispatch_trigger_timer: Option<tokio::time::Duration>,
    queue_trigger_timer: Option<tokio::time::Duration>,
    pub remote_store_addr: Vec<String>,
    use_substitutes: bool,
    roots_dir: std::path::PathBuf,
    max_retries: u32,
    retry_interval: f32,
    retry_backoff: f32,
    max_unsupported_time: jiff::SignedDuration,
    stop_queue_run_after: Option<jiff::SignedDuration>,
    pub max_concurrent_downloads: u32,
    concurrent_upload_limit: usize,
    token_list: Option<Vec<String>>,
    pub enable_fod_checker: bool,
    pub use_presigned_uploads: bool,
    pub forced_substituters: Vec<String>,
}

impl TryFrom<AppConfig> for PreparedApp {
    type Error = anyhow::Error;

    fn try_from(val: AppConfig) -> Result<Self, Self::Error> {
        let remote_store_addr = val
            .remote_store_addr
            .into_iter()
            .filter(|v| {
                v.starts_with("file://")
                    || v.starts_with("s3://")
                    || v.starts_with("ssh://")
                    || v.starts_with('/')
            })
            .collect();

        let logname = std::env::var("LOGNAME").context("LOGNAME env var missing")?;
        let nix_state_dir =
            std::env::var("NIX_STATE_DIR").unwrap_or_else(|_| "/nix/var/nix/".to_owned());
        let roots_dir = val.roots_dir.map_or_else(
            || {
                std::path::PathBuf::from(nix_state_dir)
                    .join("gcroots/per-user")
                    .join(logname)
                    .join("hydra-roots")
            },
            |roots_dir| roots_dir,
        );
        fs_err::create_dir_all(&roots_dir)?;

        let hydra_log_dir = val.hydra_data_dir.join("build-logs");
        let lockfile = val.hydra_data_dir.join("queue-runner/lock");

        let token_list = val.token_list_path.and_then(|p| {
            fs_err::read_to_string(p)
                .map(|s| s.lines().map(|t| t.trim().to_string()).collect())
                .ok()
        });

        Ok(Self {
            hydra_data_dir: val.hydra_data_dir,
            hydra_log_dir,
            lockfile,
            db_url: val.db_url,
            max_db_connections: val.max_db_connections,
            machine_sort_fn: val.machine_sort_fn,
            machine_free_fn: val.machine_free_fn,
            step_sort_fn: val.step_sort_fn,
            dispatch_trigger_timer: u64::try_from(val.dispatch_trigger_timer_in_s)
                .ok()
                .and_then(|v| {
                    if v == 0 {
                        None
                    } else {
                        Some(tokio::time::Duration::from_secs(v))
                    }
                }),
            queue_trigger_timer: u64::try_from(val.queue_trigger_timer_in_s)
                .ok()
                .and_then(|v| {
                    if v == 0 {
                        None
                    } else {
                        Some(tokio::time::Duration::from_secs(v))
                    }
                }),
            remote_store_addr,
            use_substitutes: val.use_substitutes,
            roots_dir,
            max_retries: val.max_retries,
            #[allow(clippy::cast_precision_loss)]
            retry_interval: val.retry_interval as f32,
            retry_backoff: val.retry_backoff,
            max_unsupported_time: jiff::SignedDuration::from_secs(val.max_unsupported_time_in_s),
            stop_queue_run_after: if val.stop_queue_run_after_in_s <= 0 {
                None
            } else {
                Some(jiff::SignedDuration::from_secs(
                    val.stop_queue_run_after_in_s,
                ))
            },
            max_concurrent_downloads: val.max_concurrent_downloads,
            concurrent_upload_limit: val.concurrent_upload_limit,
            token_list,
            enable_fod_checker: val.enable_fod_checker,
            use_presigned_uploads: val.use_presigned_uploads,
            forced_substituters: val.forced_substituters,
        })
    }
}

/// Loads the config from specified path
#[tracing::instrument(err)]
fn load_config(filepath: &str) -> anyhow::Result<PreparedApp> {
    tracing::info!("Trying to loading file: {filepath}");
    let toml: AppConfig = if let Ok(content) = fs_err::read_to_string(filepath) {
        toml::from_str(&content)
            .with_context(|| format!("Failed to toml load from '{filepath}'"))?
    } else {
        tracing::warn!("no config file found! Using default config");
        toml::from_str("").context("Failed to parse empty string as config")?
    };
    tracing::info!("Loaded config: {toml:?}");

    toml.try_into().context("Failed to prepare configuration")
}

#[derive(Debug, Clone)]
pub struct App {
    inner: Arc<arc_swap::ArcSwap<PreparedApp>>,
}

impl App {
    #[tracing::instrument(err)]
    pub fn init(filepath: &str) -> anyhow::Result<Self> {
        Ok(Self {
            inner: Arc::new(arc_swap::ArcSwap::from(Arc::new(load_config(filepath)?))),
        })
    }

    fn swap_inner(&self, new_val: PreparedApp) {
        self.inner.store(Arc::new(new_val));
    }

    #[must_use]
    pub fn get_hydra_log_dir(&self) -> std::path::PathBuf {
        let inner = self.inner.load();
        inner.hydra_log_dir.clone()
    }

    #[must_use]
    pub fn get_lockfile(&self) -> std::path::PathBuf {
        let inner = self.inner.load();
        inner.lockfile.clone()
    }

    #[must_use]
    pub fn get_db_url(&self) -> secrecy::SecretString {
        let inner = self.inner.load();
        inner.db_url.clone()
    }

    #[must_use]
    pub fn get_max_db_connections(&self) -> u32 {
        let inner = self.inner.load();
        inner.max_db_connections
    }

    #[must_use]
    pub fn get_machine_sort_fn(&self) -> MachineSortFn {
        let inner = self.inner.load();
        inner.machine_sort_fn
    }

    #[must_use]
    pub fn get_machine_free_fn(&self) -> MachineFreeFn {
        let inner = self.inner.load();
        inner.machine_free_fn
    }

    #[must_use]
    pub fn get_step_sort_fn(&self) -> StepSortFn {
        let inner = self.inner.load();
        inner.step_sort_fn
    }

    #[must_use]
    pub fn use_presigned_uploads(&self) -> bool {
        let inner = self.inner.load();
        inner.use_presigned_uploads
    }

    #[must_use]
    pub fn get_dispatch_trigger_timer(&self) -> Option<tokio::time::Duration> {
        let inner = self.inner.load();
        inner.dispatch_trigger_timer
    }

    #[must_use]
    pub fn get_queue_trigger_timer(&self) -> Option<tokio::time::Duration> {
        let inner = self.inner.load();
        inner.queue_trigger_timer
    }

    #[must_use]
    pub fn get_remote_store_addrs(&self) -> Vec<String> {
        let inner = self.inner.load();
        inner.remote_store_addr.clone()
    }

    #[must_use]
    pub fn get_use_substitutes(&self) -> bool {
        let inner = self.inner.load();
        inner.use_substitutes
    }

    #[must_use]
    pub fn get_roots_dir(&self) -> std::path::PathBuf {
        let inner = self.inner.load();
        inner.roots_dir.clone()
    }

    #[must_use]
    pub fn get_retry(&self) -> (u32, f32, f32) {
        let inner = self.inner.load();
        (inner.max_retries, inner.retry_interval, inner.retry_backoff)
    }

    #[must_use]
    pub fn get_max_unsupported_time(&self) -> jiff::SignedDuration {
        let inner = self.inner.load();
        inner.max_unsupported_time
    }

    #[must_use]
    pub fn get_stop_queue_run_after(&self) -> Option<jiff::SignedDuration> {
        let inner = self.inner.load();
        inner.stop_queue_run_after
    }

    #[must_use]
    pub fn get_max_concurrent_downloads(&self) -> u32 {
        let inner = self.inner.load();
        inner.max_concurrent_downloads
    }

    #[must_use]
    pub fn get_concurrent_upload_limit(&self) -> usize {
        let inner = self.inner.load();
        inner.concurrent_upload_limit
    }

    #[must_use]
    pub fn has_token_list(&self) -> bool {
        let inner = self.inner.load();
        inner.token_list.is_some()
    }

    #[must_use]
    pub fn check_if_contains_token(&self, token: &str) -> bool {
        let inner = self.inner.load();
        inner
            .token_list
            .as_ref()
            .is_some_and(|l| l.iter().any(|t| t == token))
    }

    #[must_use]
    pub fn get_enable_fod_checker(&self) -> bool {
        let inner = self.inner.load();
        inner.enable_fod_checker
    }

    #[must_use]
    pub fn get_forced_substituters(&self) -> Vec<String> {
        let inner = self.inner.load();
        inner.forced_substituters.clone()
    }
}

pub async fn reload(current_config: &App, filepath: &str, state: &Arc<crate::state::State>) {
    let new_config = match load_config(filepath) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("Failed to load new config: {e}");
            let _notify = sd_notify::notify(
                false,
                &[
                    sd_notify::NotifyState::Status("Reload failed"),
                    sd_notify::NotifyState::Errno(1),
                ],
            );

            return;
        }
    };

    if let Err(e) = state.reload_config_callback(&new_config).await {
        tracing::error!("Config reload failed with {e}");
        let _notify = sd_notify::notify(
            false,
            &[
                sd_notify::NotifyState::Status("Configuration reloaded failed - Running"),
                sd_notify::NotifyState::Errno(1),
            ],
        );
        return;
    }

    current_config.swap_inner(new_config);
    let _notify = sd_notify::notify(
        false,
        &[
            sd_notify::NotifyState::Status("Configuration reloaded - Running"),
            sd_notify::NotifyState::Ready,
        ],
    );
}
