mod handler;
mod server;
mod waiter;

use std::path::PathBuf;

use clap::Parser;
use harmonia_store_core::store_path::StoreDir;

#[derive(Parser, Debug)]
#[command(about = "Nix daemon proxy that writes derivations to Postgres")]
struct Args {
    /// Unix socket to listen on for nix daemon connections.
    #[arg(long, default_value = "/tmp/hydra-drv-daemon.sock")]
    socket: PathBuf,

    /// Upstream nix daemon socket to proxy read operations to.
    #[arg(long, default_value = "/nix/var/nix/daemon-socket/socket")]
    upstream_socket: String,

    /// PostgreSQL connection URL.
    #[arg(long, env = "HYDRA_DBA")]
    db_url: String,

    /// Nix store directory.
    #[arg(long, default_value = "/nix/store")]
    store_dir: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = Args::parse();
    let store_dir =
        StoreDir::new(&args.store_dir).map_err(|e| anyhow::anyhow!("invalid store dir: {e}"))?;
    let database = db::Database::new(&args.db_url, 4).await?;
    let waiter = waiter::BuildWaiter::start(&database).await?;
    let handler =
        handler::DrvDaemonHandler::new(store_dir.clone(), database, &args.upstream_socket, waiter);
    let server = server::DaemonServer::new(handler, args.socket, store_dir);
    server.serve().await?;
    Ok(())
}
