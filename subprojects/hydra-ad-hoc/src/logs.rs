//! Live build logs for a client that is waiting on a build.
//!
//! A local `nix-build` shows the user each derivation as it starts,
//! its log lines as they appear, and when it stops. The daemon
//! protocol carries all of that as activity messages interleaved
//! with an operation's result, so a client pointed at hydra-ad-hoc
//! can be shown the same thing: every build step the queue runner
//! dispatches becomes a `Build` activity, and the log file the queue
//! runner writes for it is tailed line by line into `BuildLogLine`
//! results, exactly as Nix itself reports a build.
//!
//! The pieces: the queue runner announces steps on `step_started` and
//! `step_finished`, which [`crate::waiter::BuildWaiter`] fans out as
//! [`StepEvent`]s; the `build-logs` crate knows where the step's log
//! file is and how to follow it. This module joins the two into one
//! stream of [`LogMessage`]s for the builds a request is waiting on.

use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use async_stream::stream;
use futures::stream::{Stream, StreamExt as _};
use harmonia_protocol::log::{
    Activity, ActivityResult, ActivityType, Field, LogMessage, ResultType, StopActivity, Verbosity,
};
use tokio::sync::{broadcast, mpsc, watch};

use build_logs::tailer::{LineKind, TailManager};
use db::StoreDir;
use db::models::BuildID;

use crate::waiter::{StepEvent, StepEventKind};

/// How long to wait for a step's log file to appear after
/// `step_started`. The queue runner creates it when the builder's
/// first log chunk arrives, which is normally well under a second
/// after dispatch; a step that produces no output at all never
/// creates one.
const LOG_FILE_WAIT: Duration = Duration::from_secs(60);
const LOG_FILE_POLL: Duration = Duration::from_millis(200);

/// After the build is finished, how long to keep draining log tails
/// that have not reached end-of-file yet.
const DRAIN_AFTER_DONE: Duration = Duration::from_secs(5);

/// How long after `step_finished` to keep following a step's log. The
/// builder sends its log and its result on separate streams, so the
/// queue runner may still be writing the file when the step is
/// reported finished, and for a short build may not have created it.
const FINISH_GRACE: Duration = Duration::from_secs(2);

/// Everything needed to turn step announcements into log messages.
#[derive(Clone)]
pub(crate) struct LogSource {
    pub(crate) db: db::Database,
    pub(crate) store_dir: StoreDir,
    /// `<hydraDataDir>/build-logs`, the queue runner's log directory.
    pub(crate) log_prefix: PathBuf,
    pub(crate) tails: Arc<TailManager>,
}

impl std::fmt::Debug for LogSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LogSource")
            .field("log_prefix", &self.log_prefix)
            .finish_non_exhaustive()
    }
}

type BoxedLogStream = Pin<Box<dyn Stream<Item = LogMessage> + Send>>;

/// Log messages for the builds announced on `builds`, until `done`
/// turns true.
///
/// `events` must have been subscribed before the first build row was
/// committed, or that build's first steps can be missed. The stream
/// ignores steps of builds it was not told about, so one broadcast
/// serves every connection.
pub(crate) fn build_log_stream(
    src: LogSource,
    mut events: broadcast::Receiver<StepEvent>,
    mut builds: mpsc::UnboundedReceiver<BuildID>,
    mut done: watch::Receiver<bool>,
) -> impl Stream<Item = LogMessage> + Send {
    stream! {
        let ids = Arc::new(AtomicU64::new(1));
        let mut interested: Vec<BuildID> = Vec::new();
        let mut steps: Vec<(StepEvent, watch::Sender<bool>)> = Vec::new();
        let mut tails = futures::stream::SelectAll::<BoxedLogStream>::new();

        loop {
            tokio::select! {
                // In order: an announced build id must be seen before any
                // step event that arrived just after it.
                biased;
                Some(build_id) = builds.recv() => {
                    interested.push(build_id);
                }
                ev = events.recv() => match ev {
                    Ok(ev) if interested.contains(&ev.build_id) => match ev.kind {
                        StepEventKind::Started => {
                            let (finished_tx, finished_rx) = watch::channel(false);
                            steps.push((ev, finished_tx));
                            tails.push(Box::pin(step_log_stream(src.clone(), ev, ids.clone(), finished_rx)));
                        }
                        StepEventKind::Finished => {
                            for (started, finished) in &steps {
                                if started.build_id == ev.build_id && started.step_nr == ev.step_nr {
                                    let _ = finished.send(true);
                                }
                            }
                        }
                    },
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!(missed = n, "step events lagged; some log output may be missing");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                },
                Some(msg) = tails.next(), if !tails.is_empty() => {
                    yield msg;
                }
                Ok(()) = done.changed() => {
                    if *done.borrow() {
                        break;
                    }
                }
            }
        }

        // The build is finished, so every step is too; give their tails
        // a moment to reach end-of-file rather than cutting them mid-line.
        for (_, finished) in &steps {
            let _ = finished.send(true);
        }
        let deadline = tokio::time::sleep(DRAIN_AFTER_DONE);
        tokio::pin!(deadline);
        while !tails.is_empty() {
            tokio::select! {
                Some(msg) = tails.next() => yield msg,
                () = &mut deadline => break,
                else => break,
            }
        }
    }
}

/// One step's worth of messages: a `Build` activity, its log lines as
/// `BuildLogLine` results, and the activity's end.
fn step_log_stream(
    src: LogSource,
    ev: StepEvent,
    ids: Arc<AtomicU64>,
    mut finished: watch::Receiver<bool>,
) -> impl Stream<Item = LogMessage> + Send {
    stream! {
        let Some(drv) = lookup_drv(&src, ev).await else {
            return;
        };
        let id = ids.fetch_add(1, Ordering::Relaxed);
        let drv_str = src.store_dir.display(&drv).to_string();
        yield LogMessage::StartActivity(Activity {
            // Nix's own `Build` activity: derivation, machine, round, rounds.
            fields: vec![
                Field::String(drv_str.clone().into()),
                Field::String(bytes::Bytes::new()),
                Field::Int(1),
                Field::Int(1),
            ],
            id,
            level: Verbosity::Info,
            parent: 0,
            text: format!("building '{drv_str}'").into(),
            activity_type: ActivityType::Build,
        });

        let path = build_logs::log_path(&src.log_prefix, &drv);
        tracing::debug!(?ev, path = %path.display(), "step started; waiting for its log");
        if wait_for_log_file(&path, &mut finished).await {
            let mut sub = src.tails.subscribe(&path).await;
            tracing::debug!(?ev, backlog = sub.backlog.len(), finished = *finished.borrow(), "following step log");
            // `step_finished` does not mean the log is complete: the builder
            // sends its log and its result on separate streams, so the queue
            // runner can still be writing the file. Close the tail a grace
            // period after the step finishes, not at once.
            let mut close_at: Option<Pin<Box<tokio::time::Sleep>>> = None;
            if *finished.borrow() {
                close_at = Some(Box::pin(tokio::time::sleep(FINISH_GRACE)));
            }
            let mut last_seq = 0;
            let backlog = std::mem::take(&mut sub.backlog);
            for m in backlog {
                last_seq = m.seq;
                match m.inner.kind {
                    LineKind::Line => yield log_line(id, m.inner.line),
                    LineKind::Error | LineKind::Eof => break,
                }
            }
            let mut open = true;
            while open {
                tokio::select! {
                    r = sub.rx.recv() => match r {
                        Ok(m) if m.seq <= last_seq => {}
                        Ok(m) => match m.inner.kind {
                            LineKind::Line => yield log_line(id, m.inner.line),
                            LineKind::Error | LineKind::Eof => open = false,
                        },
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => open = false,
                    },
                    Ok(()) = finished.changed(), if close_at.is_none() => {
                        if *finished.borrow() {
                            close_at = Some(Box::pin(tokio::time::sleep(FINISH_GRACE)));
                        }
                    }
                    () = async {
                        match close_at.as_mut() {
                            Some(sleep) => sleep.await,
                            None => std::future::pending().await,
                        }
                    }, if close_at.is_some() => {
                        src.tails.finish_tail(&path);
                        close_at = None;
                        // From here the tail runs to end-of-file and reports
                        // `Eof`, which ends the loop above.
                    }
                }
            }
        }

        tracing::debug!(?ev, "step log done");
        yield LogMessage::StopActivity(StopActivity { id });
    }
}

fn log_line(id: u64, line: String) -> LogMessage {
    LogMessage::Result(ActivityResult {
        fields: vec![Field::String(line.into())],
        id,
        result_type: ResultType::BuildLogLine,
    })
}

async fn lookup_drv(src: &LogSource, ev: StepEvent) -> Option<harmonia_store_path::StorePath> {
    let result = async {
        let mut conn = src.db.get().await?;
        let mut tx = conn.begin_transaction().await?;
        tx.get_drv_path_from_build_step(&src.store_dir, ev.build_id, ev.step_nr)
            .await
    }
    .await;
    match result {
        Ok(Some(drv)) => Some(drv),
        Ok(None) => {
            tracing::warn!(?ev, "step announced but not found in the database");
            None
        }
        Err(e) => {
            tracing::warn!(?ev, "cannot look up step's derivation: {e}");
            None
        }
    }
}

/// True once the file exists; false if the wait ran out, or the step
/// finished and a grace period passed, without one ever appearing.
async fn wait_for_log_file(path: &std::path::Path, finished: &mut watch::Receiver<bool>) -> bool {
    let deadline = tokio::time::sleep(LOG_FILE_WAIT);
    tokio::pin!(deadline);
    let mut give_up_at: Option<Pin<Box<tokio::time::Sleep>>> = None;
    loop {
        if fs_err::tokio::metadata(path).await.is_ok() {
            return true;
        }
        if give_up_at.is_none() && *finished.borrow() {
            give_up_at = Some(Box::pin(tokio::time::sleep(FINISH_GRACE)));
        }
        tokio::select! {
            () = tokio::time::sleep(LOG_FILE_POLL) => {}
            _ = finished.changed(), if give_up_at.is_none() => {}
            () = async {
                match give_up_at.as_mut() {
                    Some(sleep) => sleep.await,
                    None => std::future::pending().await,
                }
            }, if give_up_at.is_some() => {
                return fs_err::tokio::metadata(path).await.is_ok();
            }
            () = &mut deadline => return false,
        }
    }
}
