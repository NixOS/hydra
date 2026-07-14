#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

use crate::error::BuilderError;

mod config;
mod error;
mod grpc;
mod metrics;
mod nix_config;
mod state;
mod system;
mod types;
mod utils;

#[cfg(not(target_env = "msvc"))]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

fn stop_application(state: &std::sync::Arc<state::State>, abort_handle: &tokio::task::AbortHandle) {
    let _ = sd_notify::notify(&[sd_notify::NotifyState::Stopping]);
    tracing::info!("Enabling halt");
    state.enable_halt();
    tracing::info!("Aborting all active builds");
    state.abort_all_active_builds();
    tracing::info!("Closing connection with queue-runner");
    abort_handle.abort();
}

#[tokio::main]
async fn main() -> color_eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;

    let cli = config::Cli::new();

    let state = state::State::new(&cli).await?;
    let task = tokio::spawn({
        let state = state.clone();
        async move { grpc::start_bidirectional_stream(state.clone()).await }
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
            stop_application(&state, &abort_handle);
            Ok(())
        }
        _ = sigterm.recv() => {
            tracing::info!("Received sigterm - shutting down gracefully");
            stop_application(&state, &abort_handle);
            Ok(())
        }
        r = task => {
            // The runner re-queues this builder's steps when the tunnel drops.
            // Builds run in the nix daemon and outlive the tunnel, so abort
            // them here too; otherwise the same drv keeps building untracked
            // and can also be dispatched elsewhere.
            tracing::info!("Queue-runner connection lost; aborting all active builds");
            state.abort_all_active_builds();
            match r.map_err(BuilderError::from).flatten() {
                Ok(()) => Ok(()),
                Err(e) => match e {
                    BuilderError::VersionIncompatible(_) => {
                        tracing::error!("ERROR: {e:?}");
                        std::process::exit(65) // EX_DATAERR
                    },
                _=> Err(e.into())
                }
            }
        }
    }
}
