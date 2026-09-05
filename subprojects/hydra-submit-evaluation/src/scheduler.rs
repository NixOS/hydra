//! Deciding when jobsets are due, and submitting an evaluation of each.
//!
//! The database says which jobsets are due; nothing about them is kept here.
//! A submission fetches inputs and queues a build, so several may run at
//! once, and the only state worth holding is which jobsets are mid-submission
//! so the same one is not started twice.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use color_eyre::eyre;
use futures::StreamExt as _;
use tokio::sync::Notify;

use crate::config::HydraConfig;
use crate::store_paths::Availability;
use crate::submit::{self, Outcome};

/// How long to wait between looks at the database when nothing wakes us
/// sooner. Check intervals are seconds, so this bounds how late a jobset can
/// be; a jobset event or a submission finishing wakes the loop at once.
const POLL: Duration = Duration::from_secs(10);

pub(crate) async fn run(
    db: db::Database,
    config: Arc<HydraConfig>,
    available: Arc<Availability>,
) -> eyre::Result<()> {
    let mut events = db
        .listener(vec![
            "jobsets_added",
            "jobsets_deleted",
            "jobset_scheduling_changed",
        ])
        .await?;

    let in_flight = Arc::new(Mutex::new(HashSet::new()));
    let wake = Arc::new(Notify::new());

    loop {
        if let Err(e) = submit_due(&db, &config, &available, &in_flight, &wake).await {
            tracing::error!("could not submit due jobsets: {e:#}");
        }

        tokio::select! {
            () = tokio::time::sleep(POLL) => {}
            () = wake.notified() => {}
            event = events.next() => match event {
                Some(Ok(_)) => {}
                Some(Err(e)) => return Err(e.into()),
                None => eyre::bail!("the notification stream ended"),
            },
        }
    }
}

async fn submit_due(
    db: &db::Database,
    config: &Arc<HydraConfig>,
    available: &Arc<Availability>,
    in_flight: &Arc<Mutex<HashSet<i32>>>,
    wake: &Arc<Notify>,
) -> eyre::Result<()> {
    let now = now();
    let due = crate::queries::get_due_jobsets(&mut db.get().await?, now).await?;

    for jobset in due {
        if !lock(in_flight).insert(jobset.id) {
            continue;
        }

        let db = db.clone();
        let config = Arc::clone(config);
        let available = Arc::clone(available);
        let in_flight = Arc::clone(in_flight);
        let wake = Arc::clone(wake);

        tokio::spawn(async move {
            let name = format!("{}:{}", jobset.project, jobset.name);
            tracing::info!("submitting an evaluation of {name}");
            let trace = format!("{now}.{}", jobset.id);
            match submit::submit(
                &db,
                &config,
                &available,
                &jobset.project,
                &jobset.name,
                &trace,
            )
            .await
            {
                Ok(Outcome::Cached { previous }) => {
                    tracing::info!("{name}: cached, same as evaluation {previous}");
                }
                Ok(Outcome::Scheduled { eval, build }) => {
                    tracing::info!("{name}: scheduled evaluation {eval} as build {build}");
                }
                Err(e) => tracing::error!("{name}: {e:#}"),
            }
            lock(&in_flight).remove(&jobset.id);
            wake.notify_one();
        });
    }

    Ok(())
}

/// A poisoned lock only means a submission task panicked; the set is still
/// the set.
fn lock(set: &Mutex<HashSet<i32>>) -> std::sync::MutexGuard<'_, HashSet<i32>> {
    set.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub(crate) fn now() -> db::Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}
