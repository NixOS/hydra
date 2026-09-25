use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt as _;

use crate::state::State;

use build_logs::notify::{parse_build_finished_payload, parse_step_finished_payload};

const CHANNEL_STEP_FINISHED: &str = "step_finished";
const CHANNEL_BUILD_FINISHED: &str = "build_finished";

#[derive(Debug, thiserror::Error)]
pub enum ListenerError {
    #[error("Failed to create PG listener: {0}")]
    PgListener(#[from] db::Error),
}

#[tracing::instrument(skip(state))]
pub async fn run_event_listener(state: Arc<State>) -> Result<(), ListenerError> {
    let channels = vec![CHANNEL_STEP_FINISHED, CHANNEL_BUILD_FINISHED];
    tracing::info!(?channels, "starting PG event listener");
    let mut stream = state.db.listener(channels).await?;

    const MAX_BACKOFF: Duration = Duration::from_secs(30);
    let mut backoff = Duration::from_millis(100);

    loop {
        let notification = match stream.next().await {
            Some(Ok(n)) => {
                backoff = Duration::from_millis(100);
                n
            }
            Some(Err(e)) => {
                tracing::error!("PG listener error: {e}");
                tokio::time::sleep(backoff).await;
                backoff = std::cmp::min(backoff * 2, MAX_BACKOFF);
                continue;
            }
            None => {
                tracing::warn!("PG listener stream ended");
                return Ok(());
            }
        };

        let channel = notification.channel().to_string();
        let payload = notification.payload().to_string();
        tracing::debug!(channel, payload, "PG notification received");

        match channel.as_str() {
            CHANNEL_STEP_FINISHED => {
                if let Some((build_id, step_id)) = parse_step_finished_payload(&payload) {
                    state.notify_step_finished(build_id, step_id);
                } else {
                    tracing::error!("Invalid step_finished payload: {payload}");
                }
            }
            CHANNEL_BUILD_FINISHED => {
                let build_ids = parse_build_finished_payload(&payload);
                if build_ids.is_empty() {
                    tracing::error!("Invalid build_finished payload: {payload}");
                } else {
                    for build_id in build_ids {
                        state.notify_build_finished(build_id);
                    }
                }
            }
            _ => {
                tracing::warn!(channel, "unknown PG notification channel");
            }
        }
    }
}
