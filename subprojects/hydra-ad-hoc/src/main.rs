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
mod server;
mod submit;
mod waiter;

use clap::Parser;
use color_eyre::eyre;
use harmonia_store_path::StoreDir;
use secrecy::ExposeSecret as _;

use crate::handler::HydraDaemonHandler;
use crate::server::DaemonServer;
use crate::waiter::BuildWaiter;

use crate::config::{App, BindSocket, Cli};
use crate::submit::AdhocSubmitter;

#[tokio::main]
async fn main() -> eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;

    let cli = Cli::parse();
    let config = App::init(&cli.config_path)?;

    let store_dir =
        StoreDir::new(&config.store_dir).map_err(|e| eyre::eyre!("invalid store dir: {e}"))?;
    let database =
        db::Database::new(config.db_url.expose_secret(), config.max_db_connections).await?;
    let waiter = BuildWaiter::start(&database).await?;
    let submitter = AdhocSubmitter::new(database.clone()).await?;
    let handler = HydraDaemonHandler::new(
        store_dir.clone(),
        database,
        &config.upstream_socket,
        waiter,
        submitter,
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
