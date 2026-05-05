#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]
#![recursion_limit = "256"]

pub mod config;
pub mod io;
pub mod lock_file;
pub mod server;
pub mod state;
pub mod utils;

use std::future::Future;

use anyhow::Context as _;

use state::State;

#[cfg(not(target_env = "msvc"))]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

fn start_task_loops(state: &std::sync::Arc<State>) -> Vec<tokio::task::AbortHandle> {
    tracing::info!("QueueRunner starting task loops");

    let mut service_list = vec![
        spawn_config_reloader(state.clone(), state.config.clone(), &state.cli.config_path),
        state.clone().start_dispatch_loop(),
        state.clone().start_dump_status_loop(),
        state.clone().start_uploader_queue(),
    ];
    if !state.cli.disable_queue_monitor_loop {
        service_list.push(state.clone().start_queue_monitor_loop());
    }

    if let Some(fod_checker) = &state.fod_checker {
        service_list.push(fod_checker.clone().start_traverse_loop());
    }

    service_list
}

fn spawn_config_reloader(
    state: std::sync::Arc<State>,
    current_config: config::App,
    filepath: &str,
) -> tokio::task::AbortHandle {
    let filepath = filepath.to_owned();
    let task = tokio::spawn(async move {
        loop {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup()) {
                Ok(mut s) => {
                    let _ = s.recv().await;
                    tracing::info!("Reloading...");
                    config::reload(&current_config, &filepath, &state).await;
                }
                Err(e) => {
                    tracing::error!("Failed to create signal listener for SIGHUP: {e}");
                    break;
                }
            }
        }
    });
    task.abort_handle()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let tracing_guard = hydra_tracing::init()?;

    #[cfg(debug_assertions)]
    {
        // If we have a debug build we want to crash on a panic, because we use some debug_asserts,
        // and that helps validating those!
        let default_panic = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            default_panic(info);
            std::process::exit(1);
        }));
    }

    nix_utils::init_nix();
    let state = State::new(&tracing_guard).await?;
    if state.cli.status {
        state.get_status_from_main_process().await?;
        return Ok(());
    }

    let lockfile_path = state.config.get_lockfile();
    let _lock = lock_file::LockFile::acquire(&lockfile_path)
        .context("Another instance is already running.")?;

    state.clear_busy().await?; // clear busy once before starting the queue-runner

    if !state.cli.mtls_configured_correctly() {
        tracing::error!(
            "mtls configured inproperly, please pass all options: server_cert_path, server_key_path and client_ca_cert_path!"
        );
        return Err(anyhow::anyhow!("Configuration issue"));
    }

    let task_abort_handles = start_task_loops(&state);

    // Resolve listeners for both servers. When using socket activation
    // (ListenFd), we use LISTEN_FDNAMES to map names to fd indices.
    let mut listenfd = listenfd::ListenFd::from_env();
    let fd_names: Vec<String> = std::env::var("LISTEN_FDNAMES")
        .unwrap_or_default()
        .split(':')
        .map(String::from)
        .collect();

    let http_listener = match &state.cli.rest_bind {
        config::BindSocket::Tcp(s) => {
            let listener = tokio::net::TcpListener::bind(s).await?;
            listener
        }
        config::BindSocket::ListenFd => {
            let idx = fd_names.iter().position(|n| n == "rest").unwrap_or(0);
            let std_listener = listenfd.take_tcp_listener(idx)?.ok_or_else(|| {
                anyhow::anyhow!("No listenfd TCP listener at index {idx} for REST")
            })?;
            std_listener.set_nonblocking(true)?;
            tokio::net::TcpListener::from_std(std_listener)?
        }
        config::BindSocket::Unix(_) => {
            anyhow::bail!("HTTP server does not support Unix sockets");
        }
    };
    let http_addr = http_listener.local_addr()?;

    let (srv1, grpc_info): (
        std::pin::Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>>,
        String,
    ) = match &state.cli.grpc_bind {
        config::BindSocket::Tcp(s) => {
            let listener = tokio::net::TcpListener::bind(s).await?;
            let addr = listener.local_addr()?;
            let info = addr.to_string();
            (
                Box::pin(server::grpc::Server::run(listener, state.clone())),
                info,
            )
        }
        config::BindSocket::ListenFd => {
            let idx = fd_names.iter().position(|n| n == "grpc").unwrap_or(1);
            let std_listener = listenfd.take_tcp_listener(idx)?.ok_or_else(|| {
                anyhow::anyhow!("No listenfd TCP listener at index {idx} for gRPC")
            })?;
            let addr = std_listener.local_addr()?;
            let info = addr.to_string();
            std_listener.set_nonblocking(true)?;
            let listener = tokio::net::TcpListener::from_std(std_listener)?;
            (
                Box::pin(server::grpc::Server::run(listener, state.clone())),
                info,
            )
        }
        config::BindSocket::Unix(p) => {
            let listener = tokio::net::UnixListener::bind(p)?;
            let info = format!("unix:{}", p.display());
            (
                Box::pin(server::grpc::Server::run_unix(listener, state.clone())),
                info,
            )
        }
    };

    tracing::info!(
        "QueueRunner listening on grpc: {} and rest: {}",
        grpc_info,
        http_addr
    );

    let srv2 = server::http::Server::run(http_listener, state.clone());

    let task = tokio::spawn(async move {
        match futures_util::future::join(srv1, srv2).await {
            (Ok(()), Ok(())) => Ok(()),
            (Ok(()), Err(e)) => Err(anyhow::anyhow!("hyper error while awaiting handle: {e}")),
            (Err(e), Ok(())) => Err(anyhow::anyhow!("tonic error while awaiting handle: {e}")),
            (Err(e1), Err(e2)) => Err(anyhow::anyhow!(
                "tonic and hyper error while awaiting handle: {e1} | {e2}"
            )),
        }
    });

    let _notify = sd_notify::notify(&[
        sd_notify::NotifyState::Status("Running"),
        sd_notify::NotifyState::Ready,
    ]);

    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    let abort_handle = task.abort_handle();
    tokio::select! {
        _ = sigint.recv() => {
            tracing::info!("Received sigint - shutting down gracefully");
            let _ = sd_notify::notify(&[sd_notify::NotifyState::Stopping]);
            abort_handle.abort();
            for h in task_abort_handles {
                h.abort();
            }
            // removing all machines will also mark all currently running jobs as cancelled
            state.remove_all_machines().await;
            let _ = state.clear_busy().await;
            Ok(())
        }
        _ = sigterm.recv() => {
            tracing::info!("Received sigterm - shutting down gracefully");
            let _ = sd_notify::notify(&[sd_notify::NotifyState::Stopping]);
            abort_handle.abort();
            for h in task_abort_handles {
                h.abort();
            }
            // removing all machines will also mark all currently running jobs as cancelled
            state.remove_all_machines().await;
            let _ = state.clear_busy().await;
            Ok(())
        }
        r = task => {
            r??;
            Ok(())
        }
    }
}
