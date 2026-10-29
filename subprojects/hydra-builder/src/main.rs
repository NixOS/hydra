use hydra_builder::{config, error::BuilderError, grpc, state};

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

    let args = config::Args::new();
    let app_config = config::load_config(&args.config_path)?;

    let state = state::State::new(&args.cli, app_config).await?;

    let _notify = sd_notify::notify(&[
        sd_notify::NotifyState::Status("Running"),
        sd_notify::NotifyState::Ready,
    ]);

    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    loop {
        let task = tokio::spawn({
            let state = state.clone();
            async move { grpc::start_bidirectional_stream(state.clone()).await }
        });
        let abort_handle = task.abort_handle();

        let should_exit = tokio::select! {
            _ = sigint.recv() => {
                tracing::info!("Received sigint - shutting down gracefully");
                stop_application(&state, &abort_handle);
                true
            }
            _ = sigterm.recv() => {
                tracing::info!("Received sigterm - shutting down gracefully");
                stop_application(&state, &abort_handle);
                true
            }
            r = task => {
                // The runner re-queues this builder's steps when the tunnel drops.
                // Builds run in the nix daemon and outlive the tunnel, so abort
                // them here too; otherwise the same drv keeps building untracked
                // and can also be dispatched elsewhere.
                tracing::info!("Queue-runner connection lost; aborting all active builds");
                state.abort_all_active_builds();
                match r.map_err(BuilderError::from).flatten() {
                    Ok(()) => true,
                    Err(e) => {
                        if matches!(e, BuilderError::VersionIncompatible(_)) {
                            tracing::error!("ERROR: {e:?}");
                            std::process::exit(65); // EX_DATAERR
                        } else {
                            // Transient error (e.g. stream receive timeout) —
                            // wait briefly and reconnect.  Temp roots are
                            // connection-scoped, so no stale-root cleanup is
                            // needed here.
                            tracing::warn!("gRPC stream error, reconnecting in 5s: {e:?}");
                            false
                        }
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
