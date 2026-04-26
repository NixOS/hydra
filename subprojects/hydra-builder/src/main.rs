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

mod config;
mod grpc;
mod metrics;
mod state;
mod system;
mod types;

#[cfg(not(target_env = "msvc"))]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

async fn stop_application(
    state: &std::sync::Arc<state::State>,
    abort_handle: &tokio::task::AbortHandle,
) {
    let _ = sd_notify::notify(&[sd_notify::NotifyState::Stopping]);
    tracing::info!("Enabling halt");
    state.enable_halt();
    tracing::info!("Aborting all active builds");
    state.abort_all_active_builds();
    tracing::info!("Closing connection with queue-runner");
    abort_handle.abort();
    tracing::info!("Cleaning up gcroots");
    let _ = state.clear_gcroots().await;
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;
    nix_utils::init_nix();

    let cli = config::Cli::new();

    // Broadcast channel for SlotFreed messages: build tasks send on
    // `slot_freed_tx`, each gRPC tunnel stream subscribes a new receiver
    // so reconnections work transparently.
    let (slot_freed_tx, _) = tokio::sync::broadcast::channel(64);
    let state = state::State::new(&cli, slot_freed_tx).await?;

    let _notify = sd_notify::notify(&[
        sd_notify::NotifyState::Status("Running"),
        sd_notify::NotifyState::Ready,
    ]);

    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    // Reconnection loop: restart the gRPC stream on transient failures
    // instead of exiting the process.  Only fatal errors (API version
    // mismatch) cause an immediate exit.
    loop {
        let task = tokio::spawn({
            let state = state.clone();
            async move { grpc::start_bidirectional_stream(state.clone()).await }
        });
        let abort_handle = task.abort_handle();

        let should_exit = tokio::select! {
            _ = sigint.recv() => {
                tracing::info!("Received sigint - shutting down gracefully");
                stop_application(&state, &abort_handle).await;
                true
            }
            _ = sigterm.recv() => {
                tracing::info!("Received sigterm - shutting down gracefully");
                stop_application(&state, &abort_handle).await;
                true
            }
            r = task => {
                match r {
                    Ok(Ok(())) => {
                        // Stream ended cleanly — safe to clear gcroots.
                        let _ = state.clear_gcroots().await;
                        true
                    }
                    Ok(Err(e)) => {
                        let error_str = e.to_string();
                        if error_str.contains("API version mismatch") {
                            tracing::error!("ERROR: {error_str}");
                            std::process::exit(65); // EX_DATAERR
                        }
                        // Transient error — log and reconnect after a brief
                        // pause.  Do NOT clear gcroots here: background
                        // upload tasks may still be running and depend on
                        // the gcroot symlinks to protect outputs from GC.
                        tracing::warn!("gRPC stream error, reconnecting in 5s: {e}");
                        false
                    }
                    Err(e) => {
                        // Same reasoning: don't clear gcroots on panic.
                        tracing::warn!("gRPC task panicked, reconnecting in 5s: {e}");
                        false
                    }
                }
            }
        };

        if should_exit {
            break;
        }

        // Brief backoff before reconnecting to avoid tight retry loops.
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
    Ok(())
}
