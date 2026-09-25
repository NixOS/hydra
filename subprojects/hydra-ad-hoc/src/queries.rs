//! The daemon's own reads of Hydra's `Builds` table.
//!
//! These queries are compile-time checked against the shared schema
//! but belong to this daemon alone, so they live here, on the raw
//! connections the `db` crate hands out for that purpose.

use std::collections::BTreeMap;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use db::models::{BuildID, BuildStatus};

/// A build the queue runner has finished, as the daemon reports it
/// back to the client.
#[derive(Debug)]
pub(crate) struct FinishedBuild {
    pub(crate) status: BuildStatus,
    pub(crate) start_time: Option<db::Timestamp>,
    pub(crate) stop_time: Option<db::Timestamp>,
    /// From `BuildOutputs`, which the queue runner fills in for every
    /// successful build, cached or not. Empty for a failed one.
    pub(crate) outputs: BTreeMap<OutputName, StorePath>,
}

/// The finished build with `build_id`, or `None` while it is still
/// unfinished.
pub(crate) async fn get_finished_build(
    conn: &mut sqlx::PgConnection,
    store_dir: &StoreDir,
    build_id: BuildID,
) -> Result<Option<FinishedBuild>, db::Error> {
    let Some(row) = sqlx::query!(
        "SELECT buildStatus, startTime, stopTime
         FROM builds
         WHERE id = $1 AND finished = 1",
        build_id,
    )
    .fetch_optional(&mut *conn)
    .await?
    else {
        return Ok(None);
    };
    let Some(status) = row.buildstatus.and_then(BuildStatus::from_i32) else {
        return Ok(None);
    };

    let outputs = sqlx::query!(
        "SELECT name, path FROM buildoutputs WHERE build = $1 AND path IS NOT NULL",
        build_id,
    )
    .fetch_all(&mut *conn)
    .await?
    .into_iter()
    .filter_map(|r| r.path.map(|p| (r.name, p)))
    .map(|(name, path)| -> Result<_, db::Error> {
        let name: OutputName = name.parse()?;
        let path: StorePath = store_dir.parse(&path)?;
        Ok((name, path))
    })
    .collect::<Result<_, _>>()?;

    Ok(Some(FinishedBuild {
        status,
        start_time: row.starttime,
        stop_time: row.stoptime,
        outputs,
    }))
}

/// Which of `ids` are finished. For the waiter's sweep after a lost
/// notification listener: PostgreSQL does not replay missed
/// notifications, so registered builds are re-checked directly.
pub(crate) async fn finished_build_ids(
    conn: &mut sqlx::PgConnection,
    ids: &[BuildID],
) -> Result<Vec<BuildID>, db::Error> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    Ok(sqlx::query_scalar!(
        "SELECT id FROM builds WHERE id = ANY($1) AND finished = 1",
        ids,
    )
    .fetch_all(conn)
    .await?)
}
