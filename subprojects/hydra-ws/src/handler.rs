use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::SplitSink;
use futures_util::{SinkExt as _, StreamExt as _};
use harmonia_store_path::StorePath;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{Bytes, Message, Utf8Bytes};
use tokio_tungstenite::{WebSocketStream, accept_async};

use crate::config::Stream;
use crate::messages::{HydraWsRequest, HydraWsResponse};
use crate::state::State;
use crate::subscriptions::Subscriptions;
use crate::tailer::LineKind;

const OUT_CHANNEL_CAPACITY: usize = 4096;

const PING_INTERVAL: Duration = Duration::from_secs(20);

#[derive(Debug, thiserror::Error)]
pub enum ConnectionError {
    #[error("WebSocket error: {0}")]
    WebSocket(#[from] tokio_tungstenite::tungstenite::Error),
}

fn construct_log_path(log_prefix: &Path, drv: &StorePath) -> PathBuf {
    let base = drv.to_string();
    let (dir, file) = base.split_at(2);
    log_prefix.join(dir).join(file)
}

#[tracing::instrument(skip(ws_write, out_rx))]
pub fn spawn_writer(
    mut ws_write: SplitSink<WebSocketStream<Stream>, Message>,
    mut out_rx: mpsc::Receiver<HydraWsResponse>,
) {
    tokio::spawn(async move {
        let mut ping =
            tokio::time::interval_at(tokio::time::Instant::now() + PING_INTERVAL, PING_INTERVAL);
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            let msg = tokio::select! {
                resp = out_rx.recv() => {
                    let Some(resp) = resp else { break };
                    match serde_json::to_string(&resp) {
                        Ok(txt) => Message::Text(txt.into()),
                        Err(e) => {
                            tracing::error!("Failed to serialize response: {e}");
                            continue;
                        }
                    }
                }
                _ = ping.tick() => Message::Ping(Bytes::new()),
            };
            if ws_write.send(msg).await.is_err() {
                break;
            }
        }
    });
}

#[tracing::instrument(skip(out_tx))]
pub async fn handle_ping(out_tx: &mpsc::Sender<HydraWsResponse>) {
    tracing::debug!("responding to pong");
    let _ = out_tx.send(HydraWsResponse::Pong {}).await;
}

#[derive(Debug, thiserror::Error)]
pub enum LogsStartError {
    #[error("build_id out of range")]
    BuildIdOutOfRange,

    #[error("step_id out of range")]
    StepIdOutOfRange,

    #[error("Build step ({build_id}, {step_id}) not found")]
    BuildStepNotFound { build_id: i32, step_id: i32 },

    #[error("Build {build_id} not found")]
    BuildNotFound { build_id: i32 },

    #[error("Database error: {0}")]
    DBError(#[from] db::Error),

    #[error("Log file not found")]
    LogFileNotFound,

    #[error("Failed to access log file: {0}")]
    LogFileAccess(#[from] std::io::Error),

    #[error("Invalid store path: {0}")]
    StorePathParse(#[from] harmonia_store_path::ParseStorePathError),
}

impl LogsStartError {
    pub fn into_response(self, build_id: u64, step_id: Option<u64>) -> HydraWsResponse {
        HydraWsResponse::LogsStart {
            build_id,
            step_id,
            success: false,
            details: self.to_string(),
        }
    }
}

#[tracing::instrument(skip(out_tx, state), fields(%build_id, ?step_id))]
pub async fn handle_logs_start(
    build_id: u64,
    step_id: Option<u64>,
    out_tx: &mpsc::Sender<HydraWsResponse>,
    state: &Arc<State>,
) -> Result<(), LogsStartError> {
    if state.has_subscription(build_id, step_id, out_tx) {
        let _ = out_tx
            .send(HydraWsResponse::LogsStart {
                build_id,
                step_id,
                success: true,
                details: "Already following log".into(),
            })
            .await;
        return Ok(());
    }

    let build_id_i32 = i32::try_from(build_id).map_err(|_| LogsStartError::BuildIdOutOfRange)?;

    let mut conn = state.db.get().await.map_err(|e| {
        tracing::error!("DB connection failed: {e}");
        e
    })?;

    let drv_path = {
        let mut tx = conn.begin_transaction().await?;
        if let Some(step_id) = step_id {
            let step_id = i32::try_from(step_id).map_err(|_| LogsStartError::StepIdOutOfRange)?;
            tx.get_drv_path_from_build_step(&state.store_dir, build_id_i32, step_id)
                .await
                .map_err(|e| {
                    tracing::error!("DB query failed: {e}");
                    e
                })?
                .ok_or(LogsStartError::BuildStepNotFound {
                    build_id: build_id_i32,
                    step_id,
                })?
        } else {
            tx.get_drv_path_from_build(&state.store_dir, build_id_i32)
                .await
                .map_err(|e| {
                    tracing::error!("DB query failed: {e}");
                    e
                })?
                .ok_or(LogsStartError::BuildNotFound {
                    build_id: build_id_i32,
                })?
        }
    };

    let path = construct_log_path(&state.get_log_prefix(), &drv_path);
    tracing::info!("Start streaming path: {:?}", path);

    match fs_err::tokio::metadata(&path).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::error!("Log file not found: {:?}", path);
            return Err(LogsStartError::LogFileNotFound);
        }
        Err(e) => {
            tracing::error!("Failed to stat log file: {e}");
            return Err(LogsStartError::LogFileAccess(e));
        }
    }

    let sub_path = path.clone();
    let (start_tx, start_rx) = oneshot::channel();
    let handle = spawn_tail_forwarder(
        build_id,
        step_id,
        path,
        out_tx.clone(),
        state.clone(),
        start_rx,
    );
    state.register_subscription(build_id, step_id, handle, out_tx.clone(), sub_path);
    let _ = start_tx.send(());
    Ok(())
}

#[tracing::instrument(skip(out_tx, subscriptions), fields(%build_id, ?step_id))]
pub async fn handle_logs_end(
    build_id: u64,
    step_id: Option<u64>,
    out_tx: &mpsc::Sender<HydraWsResponse>,
    subscriptions: &Subscriptions,
) {
    if subscriptions.abort(build_id, step_id, out_tx) {
        let _ = out_tx
            .send(HydraWsResponse::LogsEnd {
                build_id,
                step_id,
                success: true,
                details: String::new(),
            })
            .await;
    } else {
        let _ = out_tx
            .send(HydraWsResponse::LogsEnd {
                build_id,
                step_id,
                success: false,
                details: "Was not following log".into(),
            })
            .await;
    }
}

async fn send_log_complete(
    build_id: u64,
    step_id: Option<u64>,
    out_tx: &mpsc::Sender<HydraWsResponse>,
    state: &Arc<State>,
) {
    let _ = out_tx
        .send(HydraWsResponse::LogsEnd {
            build_id,
            step_id,
            success: true,
            details: String::new(),
        })
        .await;
    state.cleanup_subscription(build_id, step_id, out_tx);
}

#[tracing::instrument(skip(out_tx, state, start_rx), fields(%build_id, ?step_id, path = %path.display()))]
fn spawn_tail_forwarder(
    build_id: u64,
    step_id: Option<u64>,
    path: PathBuf,
    out_tx: mpsc::Sender<HydraWsResponse>,
    state: Arc<State>,
    start_rx: oneshot::Receiver<()>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        if start_rx.await.is_err() {
            return;
        }

        let mut sub = state.subscribe(path).await;
        let _ = out_tx
            .send(HydraWsResponse::LogsStart {
                build_id,
                step_id,
                success: true,
                details: String::new(),
            })
            .await;

        let mut last_seq = 0u64;
        for m in &sub.backlog {
            last_seq = last_seq.max(m.seq);
            match m.inner.kind {
                LineKind::Line => {
                    if out_tx
                        .send(HydraWsResponse::LogLine {
                            build_id,
                            step_id,
                            timestamp: m.inner.timestamp,
                            line: m.inner.line.clone(),
                        })
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
                LineKind::Error => {
                    let _ = out_tx
                        .send(HydraWsResponse::LogsEnd {
                            build_id,
                            step_id,
                            success: false,
                            details: m.inner.line.clone(),
                        })
                        .await;
                    state.cleanup_subscription(build_id, step_id, &out_tx);
                    return;
                }
                LineKind::Eof => {
                    send_log_complete(build_id, step_id, &out_tx, &state).await;
                    return;
                }
            }
        }

        let rx = &mut sub.rx;
        loop {
            match rx.recv().await {
                Ok(m) => {
                    if m.seq <= last_seq {
                        continue;
                    }
                    match m.inner.kind {
                        LineKind::Line => {
                            if out_tx
                                .send(HydraWsResponse::LogLine {
                                    build_id,
                                    step_id,
                                    timestamp: m.inner.timestamp,
                                    line: m.inner.line,
                                })
                                .await
                                .is_err()
                            {
                                return;
                            }
                        }
                        LineKind::Error => {
                            let _ = out_tx
                                .send(HydraWsResponse::LogsEnd {
                                    build_id,
                                    step_id,
                                    success: false,
                                    details: m.inner.line,
                                })
                                .await;
                            state.cleanup_subscription(build_id, step_id, &out_tx);
                            return;
                        }
                        LineKind::Eof => {
                            send_log_complete(build_id, step_id, &out_tx, &state).await;
                            return;
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_skipped)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    send_log_complete(build_id, step_id, &out_tx, &state).await;
                    return;
                }
            }
        }
    })
}

#[derive(Debug)]
enum Incoming {
    Request(Utf8Bytes),
    Ignore,
    Close,
    Invalid,
}

fn classify(msg: Message) -> Incoming {
    match msg {
        Message::Text(data) => Incoming::Request(data),
        Message::Close(_) => Incoming::Close,
        Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => Incoming::Ignore,
        Message::Binary(_) => Incoming::Invalid,
    }
}

#[tracing::instrument(skip(state, stream))]
pub(crate) async fn handle_connection(
    stream: Stream,
    state: Arc<State>,
) -> Result<(), ConnectionError> {
    let ws_stream = accept_async(stream).await?;
    let (ws_write, mut ws_read) = ws_stream.split();

    let (out_tx, out_rx) = mpsc::channel::<HydraWsResponse>(OUT_CHANNEL_CAPACITY);
    spawn_writer(ws_write, out_rx);

    while let Some(msg) = ws_read.next().await {
        let Ok(msg) = msg else {
            continue;
        };
        let data = match classify(msg) {
            Incoming::Request(data) => data,
            Incoming::Ignore => continue,
            Incoming::Close => break,
            Incoming::Invalid => {
                tracing::error!("Invalid Request: message is not of type text");
                let _ = out_tx.try_send(HydraWsResponse::InvalidRequest {
                    details: "Not text".into(),
                });
                continue;
            }
        };
        let Ok(data) = serde_json::from_str::<HydraWsRequest>(&data) else {
            let _ = out_tx.try_send(HydraWsResponse::InvalidRequest {
                details: "Invalid JSON".into(),
            });
            continue;
        };

        match data {
            HydraWsRequest::Ping {} => handle_ping(&out_tx).await,
            HydraWsRequest::LogsStart { build_id, step_id } => {
                if let Err(e) = handle_logs_start(build_id, step_id, &out_tx, &state).await {
                    let _ = out_tx.send(e.into_response(build_id, step_id)).await;
                }
            }
            HydraWsRequest::LogsEnd { build_id, step_id } => {
                handle_logs_end(build_id, step_id, &out_tx, state.get_subscriptions()).await;
            }
        }
    }

    state.cleanup_connection(&out_tx);
    tracing::info!("connection closed");
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use std::path::PathBuf;
    use tokio::sync::mpsc;

    use super::*;

    #[tokio::test]
    async fn handle_ping_sends_pong() {
        let (tx, mut rx) = mpsc::channel(16);
        handle_ping(&tx).await;
        let msg = rx.try_recv().expect("should have received Pong");
        assert!(matches!(msg, HydraWsResponse::Pong {}));
    }

    #[tokio::test]
    async fn handle_logs_end_success_removes_subscription() {
        let subs = Subscriptions::new();
        let (tx, mut rx) = mpsc::channel(16);
        subs.register(
            42,
            Some(1),
            tokio::spawn(std::future::pending::<()>()),
            tx.clone(),
            PathBuf::from("/tmp/test"),
        );

        assert!(subs.has(42, Some(1), &tx));
        handle_logs_end(42, Some(1), &tx, &subs).await;

        let msg = rx.try_recv().expect("should have received LogsEnd");
        assert!(!subs.has(42, Some(1), &tx));
        assert!(
            matches!(
                msg,
                HydraWsResponse::LogsEnd {
                    build_id: 42,
                    step_id: Some(1),
                    success: true,
                    ..
                }
            ),
            "expected success LogsEnd, got {msg:?}"
        );
    }

    #[tokio::test]
    async fn handle_logs_end_not_subscribed_returns_failure() {
        let subs = Subscriptions::new();
        let (tx, mut rx) = mpsc::channel(16);

        handle_logs_end(42, None, &tx, &subs).await;

        let msg = rx.try_recv().expect("should have received LogsEnd");
        assert!(
            matches!(msg, HydraWsResponse::LogsEnd { build_id: 42, step_id: None, success: false, ref details, .. } if *details == "Was not following log"),
            "expected failure LogsEnd, got {msg:?}"
        );
    }
}
