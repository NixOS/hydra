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

use crate::handler::handle_connection;
use crate::pg_listener::run_event_listener;
use crate::state::State;

mod config;
mod handler;
mod messages;
mod pg_listener;
mod state;
mod subscriptions;
mod tailer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;

    let cli = config::Cli::new();
    let state = std::sync::Arc::new(State::new(cli).await?);

    let listener = state.bind().await?;
    tracing::info!(bind = %state.get_bind());

    let _notify = sd_notify::notify(&[
        sd_notify::NotifyState::Status("Running"),
        sd_notify::NotifyState::Ready,
    ]);

    let event_state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = run_event_listener(event_state).await {
            tracing::error!("Event listener exited with error: {e}");
        }
    });

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tracing::info!("accepted connection");
                tokio::spawn({
                    let state = state.clone();
                    async move {
                        if let Err(e) = handle_connection(stream, state).await {
                            tracing::error!("Failed to handle connection: {e}");
                        }
                    }
                });
            }
            Err(e) => {
                tracing::error!("Accept failed: {e}");
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
}
