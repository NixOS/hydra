#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    unused_qualifications
)]

//! Hydra as one giant nix daemon: a nix-daemon protocol endpoint for
//! ad hoc jobs and ad hoc store usage. This is a new, optional and
//! still experimental component; nothing else in Hydra depends on it.
//!
//! A client that speaks the
//! protocol — `nix-build`, `nix-store --realise` — asks its store to
//! realise a derivation and blocks. Pointing it at this socket makes
//! that request land in Hydra's `Builds` table instead of building
//! locally, so the queue runner and its builders do the host-side
//! work. Read operations and store uploads are proxied to an upstream
//! nix-daemon.
//!
//! Such a request carries no context, so every build it asks for is
//! filed under one hidden `adhoc/adhoc` jobset (see [`AdhocSubmitter`]).

mod config;
mod handler;
mod logs;
mod queries;
mod server;
mod submit;
mod waiter;

use clap::Parser;
use color_eyre::eyre;
use secrecy::ExposeSecret as _;

use crate::handler::HydraDaemonHandler;
use crate::logs::LogSource;
use crate::server::DaemonServer;
use crate::waiter::BuildWaiter;

use crate::config::{App, BindSocket, Cli};
use crate::submit::AdhocSubmitter;

#[tokio::main]
async fn main() -> eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;

    let cli = Cli::parse();
    let config = App::init(&cli.config_path)?;

    let store_dir = config.store_dir;
    let database =
        db::Database::new(config.db_url.expose_secret(), config.max_db_connections).await?;
    let waiter = BuildWaiter::start(&database).await?;
    let submitter = AdhocSubmitter::new(database.clone()).await?;
    let logs = LogSource {
        db: database.clone(),
        store_dir: store_dir.clone(),
        log_prefix: config.log_prefix.clone(),
        tails: std::sync::Arc::new(build_logs::tailer::TailManager::new(
            std::time::Duration::from_secs(5),
        )),
    };
    let handler = HydraDaemonHandler::new(
        store_dir.clone(),
        database,
        &config.upstream_socket,
        waiter,
        submitter,
        logs,
    );

    let server = match &cli.socket {
        BindSocket::Path(path) => DaemonServer::bind(handler, path.clone(), store_dir)?,
        BindSocket::ListenFd => {
            DaemonServer::from_listener(handler, BindSocket::inherited()?, store_dir)
        }
    };
    tracing::info!(bind = %cli.socket);

    let _notify = sd_notify::notify(&[
        sd_notify::NotifyState::Status("Running"),
        sd_notify::NotifyState::Ready,
    ]);

    server.serve().await?;
    Ok(())
}
