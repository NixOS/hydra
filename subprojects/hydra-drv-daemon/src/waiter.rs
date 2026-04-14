//! Async wakeup for ad-hoc Builds finished by the Hydra queue runner.
//!
//! The daemon listens on the `build_finished` postgres channel and
//! dispatches each notification to the waiting handler that registered
//! the build id.
//!
//! Reliability rules:
//!
//! * If the listener loses its connection, the registry of waiters is
//!   *kept*: a waiter that registered while healthy survives transient
//!   reconnects. The task retries with exponential backoff. The strike
//!   counter is shared between "listener construction failed" and
//!   "listener stream errored mid-flight" so a flaky construct ->
//!   immediate-error loop still trips the exit threshold.
//!
//! * After reconnect, finished registered builds are swept from the DB
//!   before new registrations are allowed; PostgreSQL does not replay
//!   missed notifications.
//!
//! * While the listener is unhealthy, `register` returns
//!   `RegisterError::Unhealthy` so handlers can fail their request
//!   instead of inserting a *new* row that can race with the gap.
//!
//! * After `MAX_RECONNECT_ATTEMPTS` consecutive strikes the task
//!   drains all pending waiters and `std::process::exit(1)`s so a
//!   service supervisor can restart the daemon with a clean slate.
//!   Drained waiters yield `Err(RecvError)` and their handlers
//!   surface a build-failure response.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures::StreamExt as _;
use tokio::sync::{Mutex, oneshot};

use db::models::BuildID;

const MAX_RECONNECT_ATTEMPTS: u32 = 5;
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

type WaiterMap = Arc<Mutex<HashMap<BuildID, oneshot::Sender<()>>>>;

#[derive(Debug, thiserror::Error)]
pub enum RegisterError {
    #[error("build_finished listener is currently unhealthy; refusing to register a waiter")]
    Unhealthy,
}

/// Registry of in-flight ad-hoc builds. Cloning shares the same backing
/// state, so all daemon connections wake from the same listener task.
#[derive(Clone)]
pub struct BuildWaiter {
    waiters: WaiterMap,
    healthy: Arc<AtomicBool>,
}

impl std::fmt::Debug for BuildWaiter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BuildWaiter").finish_non_exhaustive()
    }
}

impl BuildWaiter {
    pub async fn start(db: &db::Database) -> Result<Self, db::Error> {
        // Verify LISTEN works before accepting registrations.
        drop(db.listener(vec!["build_finished"]).await?);

        let waiters: WaiterMap = Arc::new(Mutex::new(HashMap::new()));
        let healthy = Arc::new(AtomicBool::new(true));
        tokio::spawn(run_listener(db.clone(), waiters.clone(), healthy.clone()));

        Ok(Self { waiters, healthy })
    }

    /// Register a build while the listener is healthy; existing waiters survive reconnect and may be woken by the sweep.
    pub async fn register(
        &self,
        build_id: BuildID,
    ) -> Result<oneshot::Receiver<()>, RegisterError> {
        if !self.healthy.load(Ordering::Acquire) {
            return Err(RegisterError::Unhealthy);
        }
        let (tx, rx) = oneshot::channel();
        self.waiters.lock().await.insert(build_id, tx);
        Ok(rx)
    }

    /// Drop a pending registration without waking it. Used to clean up
    /// when a caller bails out before the build finishes.
    pub async fn forget(&self, build_id: BuildID) {
        self.waiters.lock().await.remove(&build_id);
    }
}

async fn run_listener(db: db::Database, waiters: WaiterMap, healthy: Arc<AtomicBool>) {
    let mut strike = 0u32;
    loop {
        let stream = match db.listener(vec!["build_finished"]).await {
            Ok(s) => s,
            Err(e) => {
                strike += 1;
                healthy.store(false, Ordering::Release);
                tracing::error!(
                    strike,
                    max_strikes = MAX_RECONNECT_ATTEMPTS,
                    "build_finished listener reconnect failed: {e}"
                );
                if strike >= MAX_RECONNECT_ATTEMPTS {
                    tracing::error!(
                        "giving up on build_finished listener; exiting so a supervisor can restart"
                    );
                    drain_waiters(&waiters).await;
                    std::process::exit(1);
                }
                tokio::time::sleep(backoff_for(strike)).await;
                continue;
            }
        };

        // Sweep after LISTEN because PostgreSQL does not replay missed notifications.
        if let Err(e) = sweep_already_finished(&db, &waiters).await {
            // A listener without a working DB query cannot safely become healthy.
            strike += 1;
            tracing::error!(
                strike,
                max_strikes = MAX_RECONNECT_ATTEMPTS,
                "post-reconnect sweep failed: {e}"
            );
            if strike >= MAX_RECONNECT_ATTEMPTS {
                tracing::error!("giving up on build_finished listener; exiting");
                drain_waiters(&waiters).await;
                std::process::exit(1);
            }
            tokio::time::sleep(backoff_for(strike)).await;
            continue;
        }

        healthy.store(true, Ordering::Release);

        let mut stream = Box::pin(stream);
        let mut got_notification = false;
        loop {
            match stream.next().await {
                Some(Ok(notif)) => {
                    got_notification = true;
                    dispatch(&notif, &waiters).await;
                }
                Some(Err(e)) => {
                    tracing::error!("build_finished listener error: {e}");
                    break;
                }
                None => {
                    tracing::warn!("build_finished listener stream ended unexpectedly");
                    break;
                }
            }
        }

        // Keep registered waiters across the LISTEN gap; reset strikes only after a useful notification.
        healthy.store(false, Ordering::Release);
        if got_notification {
            strike = 0;
        } else {
            strike += 1;
            if strike >= MAX_RECONNECT_ATTEMPTS {
                tracing::error!("listener kept failing without delivering anything; exiting");
                drain_waiters(&waiters).await;
                std::process::exit(1);
            }
            tokio::time::sleep(backoff_for(strike)).await;
        }
    }
}

async fn drain_waiters(waiters: &WaiterMap) {
    let mut map = waiters.lock().await;
    let count = map.len();
    if count > 0 {
        tracing::warn!(count, "dropping pending build_finished waiters before exit");
        // Dropping senders wakes receivers with RecvError.
        map.clear();
    }
}

async fn sweep_already_finished(db: &db::Database, waiters: &WaiterMap) -> Result<(), db::Error> {
    let registered: Vec<BuildID> = {
        let map = waiters.lock().await;
        map.keys().copied().collect()
    };
    if registered.is_empty() {
        return Ok(());
    }

    let mut conn = db.get().await?;
    let finished = conn.finished_build_ids(&registered).await?;
    if finished.is_empty() {
        return Ok(());
    }

    tracing::info!(
        count = finished.len(),
        "waking waiters for builds that finished during the listener gap"
    );

    let mut map = waiters.lock().await;
    for id in finished {
        if let Some(tx) = map.remove(&id) {
            let _ = tx.send(());
        }
    }
    Ok(())
}

async fn dispatch(notif: &sqlx::postgres::PgNotification, waiters: &WaiterMap) {
    let payload = notif.payload();
    let mut map = waiters.lock().await;
    for id_str in payload.split('\t') {
        let Ok(id) = id_str.parse::<BuildID>() else {
            continue;
        };
        if let Some(tx) = map.remove(&id) {
            let _ = tx.send(());
        }
    }
}

fn backoff_for(strike: u32) -> Duration {
    let exp = INITIAL_BACKOFF
        .checked_mul(2u32.saturating_pow(strike.saturating_sub(1)))
        .unwrap_or(MAX_BACKOFF);
    exp.min(MAX_BACKOFF)
}
