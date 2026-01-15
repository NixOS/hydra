#![deny(clippy::all)]
#![deny(clippy::pedantic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]

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
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Stopping]);
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

    let state = state::State::new(&cli).await?;
    let task = tokio::spawn({
        let state = state.clone();
        async move { crate::grpc::start_bidirectional_stream(state.clone()).await }
    });

    let _notify = sd_notify::notify(
        false,
        &[
            sd_notify::NotifyState::Status("Running"),
            sd_notify::NotifyState::Ready,
        ],
    );

    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    let abort_handle = task.abort_handle();

    tokio::select! {
        _ = sigint.recv() => {
            tracing::info!("Received sigint - shutting down gracefully");
            stop_application(&state, &abort_handle).await;
        }
        _ = sigterm.recv() => {
            tracing::info!("Received sigterm - shutting down gracefully");
            stop_application(&state, &abort_handle).await;
        }
        r = task => {
            let _ = state.clear_gcroots().await;
            match r {
                Ok(Ok(())) => (),
                Ok(Err(e)) => {
                    let error_str = e.to_string();
                    if error_str.contains("API version mismatch") {
                        tracing::error!("ERROR: {error_str}");
                        std::process::exit(65); // EX_DATAERR
                    } else {
                        return Err(e);
                    }
                }
                Err(e) => return Err(e.into()),
            }
        }
    };
    Ok(())
}
