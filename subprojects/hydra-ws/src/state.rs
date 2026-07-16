use std::io;
use std::path::{Path, PathBuf};

use harmonia_store_path::StoreDir;
use secrecy::ExposeSecret;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::config::{App, BindSocket, Cli, Listener};
use crate::messages::HydraWsResponse;
use crate::subscriptions::Subscriptions;
use crate::tailer::{TailManager, TailSubscription};

#[derive(Debug, thiserror::Error)]
pub enum StateError {
    #[error(transparent)]
    Config(#[from] crate::config::ConfigError),

    #[error(transparent)]
    Database(#[from] db::Error),
}

pub struct State {
    cli: Cli,
    manager: TailManager,
    pub db: db::Database,
    config: App,
    subscriptions: Subscriptions,
    pub store_dir: StoreDir,
}

impl State {
    pub async fn new(cli: Cli) -> Result<Self, StateError> {
        let config = App::init(&cli.config_path)?;
        let db =
            db::Database::new(config.db_url.expose_secret(), config.max_db_connections).await?;
        let store_dir = StoreDir::new(
            std::env::var("NIX_STORE_DIR").unwrap_or_else(|_| "/nix/store".to_owned()),
        )
        .unwrap_or_default();
        Ok(Self {
            cli,
            manager: TailManager::new(std::time::Duration::from_secs(config.idle_grace)),
            db,
            config,
            subscriptions: Subscriptions::new(),
            store_dir,
        })
    }

    pub fn get_log_prefix(&self) -> PathBuf {
        self.config.log_prefix.clone()
    }

    pub fn get_bind(&self) -> &BindSocket {
        &self.cli.bind
    }

    pub async fn bind(&self) -> io::Result<Listener> {
        self.cli.bind.bind().await
    }

    pub async fn subscribe<P: AsRef<Path>>(&self, path: P) -> TailSubscription {
        self.manager.subscribe(path).await
    }

    pub fn has_subscription(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        tx: &mpsc::Sender<HydraWsResponse>,
    ) -> bool {
        self.subscriptions.has(build_id, step_id, tx)
    }

    pub fn register_subscription(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        handle: JoinHandle<()>,
        tx: mpsc::Sender<HydraWsResponse>,
        path: PathBuf,
    ) {
        self.subscriptions
            .register(build_id, step_id, handle, tx, path);
    }

    pub fn cleanup_subscription(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        tx: &mpsc::Sender<HydraWsResponse>,
    ) {
        self.subscriptions.cleanup(build_id, step_id, tx);
    }

    pub fn cleanup_connection(&self, tx: &mpsc::Sender<HydraWsResponse>) {
        self.subscriptions.cleanup_connection(tx);
    }

    pub fn notify_step_finished(&self, build_id: u64, step_id: u64) {
        let paths = self.subscriptions.notify_step_finished(build_id, step_id);
        for p in paths {
            self.manager.shutdown_tail(&p);
        }
    }

    pub fn notify_build_finished(&self, build_id: u64) {
        let paths = self.subscriptions.notify_build_finished(build_id);
        for p in paths {
            self.manager.shutdown_tail(&p);
        }
    }

    pub fn get_subscriptions(&self) -> &Subscriptions {
        &self.subscriptions
    }
}
