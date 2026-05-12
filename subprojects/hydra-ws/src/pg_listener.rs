use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt as _;

use crate::state::State;

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
                if let Some(build_id) = parse_build_finished_payload(&payload) {
                    state.notify_build_finished(build_id);
                } else {
                    tracing::error!("Invalid build_finished payload: {payload}");
                }
            }
            _ => {
                tracing::warn!(channel, "unknown PG notification channel");
            }
        }
    }
}

fn parse_step_finished_payload(payload: &str) -> Option<(u64, u64)> {
    let parts: Vec<&str> = payload.split('\t').collect();
    if parts.len() < 3 {
        return None;
    }
    Some((parts[0].parse().ok()?, parts[1].parse().ok()?))
}

fn parse_build_finished_payload(payload: &str) -> Option<u64> {
    payload.split('\t').next().and_then(|s| s.parse().ok())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::{parse_build_finished_payload, parse_step_finished_payload};

    #[test]
    fn parse_step_finished_valid() {
        let result = parse_step_finished_payload("42\t5\tlogfile");
        assert_eq!(result, Some((42, 5)));
    }

    #[test]
    fn parse_step_finished_too_few_parts() {
        let result = parse_step_finished_payload("42");
        assert!(result.is_none());
    }

    #[test]
    fn parse_step_finished_invalid_ids() {
        let result = parse_step_finished_payload("abc\t5\tlog");
        assert!(result.is_none());
    }

    #[test]
    fn parse_build_finished_valid() {
        let result = parse_build_finished_payload("42");
        assert_eq!(result, Some(42));
    }
}
