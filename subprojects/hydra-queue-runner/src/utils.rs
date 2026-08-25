use std::{collections::BTreeMap, os::unix::ffi::OsStrExt as _};

use db::models::BuildID;
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use crate::state::{RemoteBuild, StateError};

/// [`db::retry_serialization_failures`] pinned to [`StateError`] so callers get
/// error-type inference for the closure body.
///
/// The evaluator rewrites `builds.drvpath` in a large transaction while we mark
/// builds finished; the two occasionally deadlock. Without this retry a
/// completion that loses the deadlock would leave the build unfinished.
pub async fn with_serialization_retry<F, Fut, T>(what: &str, f: F) -> Result<T, StateError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, StateError>>,
{
    db::retry_serialization_failures(what, f).await
}

#[tracing::instrument(skip(db, store_dir, res), err)]
pub async fn finish_build_step(
    db: &db::Database,
    store_dir: &StoreDir,
    build_id: BuildID,
    step_nr: i32,
    res: &RemoteBuild,
    machine: Option<&str>,
    output_paths: Option<&BTreeMap<OutputName, StorePath>>,
) -> Result<(), StateError> {
    debug_assert!(res.has_start_time());
    debug_assert!(res.has_stop_time());
    tracing::info!(
        "Writing buildstep result in db. step_status={:?} start_time={:?} stop_time={:?}",
        res.step_status,
        res.get_start_time_as_i32(),
        res.get_stop_time_as_i32(),
    );
    debug_assert!(!res.log_file.as_os_str().is_empty());
    debug_assert!(!res.log_file.as_os_str().as_bytes().contains(&b'\t'));

    let start_time = res.get_start_time_as_i32()?;
    let stop_time = res.get_stop_time_as_i32()?;
    let log_file = res.log_file.to_str().ok_or(StateError::LogPathNotUtf8)?;

    with_serialization_retry("finish_build_step", || async {
        let mut conn = db.get().await?;
        let mut tx = conn.begin_transaction().await?;

        tx.update_build_step_in_finish(db::models::UpdateBuildStepInFinish {
            build_id,
            step_nr,
            status: res.step_status,
            error_msg: res.error_msg.as_deref(),
            start_time,
            stop_time,
            machine,
            overhead: res.get_overhead(),
            times_built: res.get_times_built(),
            is_non_deterministic: res.get_is_non_deterministic(),
        })
        .await?;

        tx.notify_step_finished(build_id, step_nr, log_file).await?;

        if res.step_status == db::models::BuildStatus::Success
            && let Some(output_paths) = output_paths
        {
            for (name, path) in output_paths {
                tx.update_build_step_output(store_dir, build_id, step_nr, name.as_ref(), path)
                    .await?;
            }
        }

        tx.commit().await?;
        Ok(())
    })
    .await
}

#[tracing::instrument(skip(db, store, connector, remote_store), fields(%drv_path), err(level=tracing::Level::WARN))]
#[allow(clippy::too_many_arguments)]
pub async fn substitute_output(
    db: db::Database,
    store: &daemon_client_utils::DaemonStoreReader,
    connector: daemon_client_utils::DaemonConnector,
    o: (OutputName, Option<StorePath>),
    build_id: BuildID,
    drv_path: &StorePath,
    remote_store: Option<&binary_cache::S3BinaryCacheClient>,
) -> Result<bool, StateError> {
    let (name, path) = o;
    let Some(path) = path else {
        return Ok(false);
    };

    let store_dir = connector.store_dir();
    let starttime = i32::try_from(jiff::Timestamp::now().as_second())?; // TODO
    let mut conn = connector.connect().await?;
    if let Err(e) = daemon_client_utils::ensure_path(&mut conn, &path).await {
        tracing::debug!("Path not found, can't import={e}");
        return Ok(false);
    }
    if let Some(remote_store) = remote_store {
        let _: Result<(), StateError> = async {
            let closure = store.query_closure_infos(vec![path.clone()]).await?;
            let missing: hashbrown::HashSet<StorePath> = remote_store
                .query_missing_paths(closure.iter().map(|vpi| vpi.path.clone()).collect())
                .await
                .into_iter()
                .collect();
            let paths_to_copy: Vec<_> = closure
                .into_iter()
                .filter(|vpi| missing.contains(&vpi.path))
                .collect();
            remote_store
                .copy_paths(connector.store_dir(), paths_to_copy, false)
                .await?;
            Ok(())
        }
        .await
        .inspect_err(|e| {
            tracing::error!(
                "Failed to copy paths to remote store({}): {e}",
                remote_store.cfg.client_config.bucket
            );
        });
    }
    let stoptime = i32::try_from(jiff::Timestamp::now().as_second())?; // TODO

    let mut db = db.get().await?;
    let mut tx = db.begin_transaction().await?;
    tx.create_substitution_step(
        store_dir,
        starttime,
        stoptime,
        build_id,
        drv_path,
        (name.clone(), Some(path.clone())),
    )
    .await?;
    tx.commit().await?;

    Ok(true)
}

#[tracing::instrument(skip(db, store_dir), fields(%drv_path), err(level=tracing::Level::WARN))]
pub async fn make_local_step(
    db: &db::Database,
    store_dir: &StoreDir,
    build_id: BuildID,
    drv_path: &StorePath,
    missing: &BTreeMap<OutputName, Option<StorePath>>,
) -> Result<(), StateError> {
    let time = i32::try_from(jiff::Timestamp::now().as_second())?;

    let mut db = db.get().await?;
    let mut tx = db.begin_transaction().await?;
    tx.create_local_step(
        store_dir,
        time,
        time,
        build_id,
        drv_path,
        missing
            .iter()
            .filter_map(|(name, path)| path.as_ref().map(|p| (name.clone(), p.clone())))
            .collect(),
    )
    .await?;
    tx.commit().await?;
    Ok(())
}
