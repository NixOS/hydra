use std::collections::BTreeMap;

use db::models::BuildID;
use nix_utils::{BaseStore as _, StorePath};

use crate::state::{BuildTimings, RemoteBuild};

#[tracing::instrument(skip(db, store, res, timings), err)]
pub async fn finish_build_step(
    db: &db::Database,
    store: &nix_utils::LocalStore,
    build_id: BuildID,
    step_nr: i32,
    res: &RemoteBuild,
    machine: Option<&str>,
    output_paths: Option<&BTreeMap<nix_utils::OutputName, StorePath>>,
    timings: BuildTimings,
) -> anyhow::Result<()> {
    let mut conn = db.get().await?;
    let mut tx = conn.begin_transaction().await?;

    debug_assert!(res.has_start_time());
    debug_assert!(res.has_stop_time());
    tracing::info!(
        "Writing buildstep result in db. step_status={:?} start_time={:?} stop_time={:?}",
        res.step_status,
        res.get_start_time_as_i32(),
        res.get_stop_time_as_i32(),
    );
    tx.update_build_step_in_finish(db::models::UpdateBuildStepInFinish {
        build_id,
        step_nr,
        status: res.step_status,
        error_msg: res.error_msg.as_deref(),
        start_time: res.get_start_time_as_i32()?,
        stop_time: res.get_stop_time_as_i32()?,
        machine,
        overhead: res.get_overhead(),
        import_time_ms: i32::try_from(timings.import_elapsed.as_millis()).ok(),
        build_time_ms: i32::try_from(timings.build_elapsed.as_millis()).ok(),
        upload_time_ms: i32::try_from(timings.upload_elapsed.as_millis()).ok(),
        times_built: res.get_times_built(),
        is_non_deterministic: res.get_is_non_deterministic(),
    })
    .await?;
    debug_assert!(!res.log_file.is_empty());
    debug_assert!(!res.log_file.contains('\t'));

    tx.notify_step_finished(build_id, step_nr, &res.log_file)
        .await?;

    if res.step_status == db::models::BuildStatus::Success
        && let Some(output_paths) = output_paths
    {
        for (name, path) in output_paths {
            tx.update_build_step_output(store.store_dir(), build_id, step_nr, name.as_ref(), path)
                .await?;
        }
    }

    tx.commit().await?;
    Ok(())
}

#[tracing::instrument(skip(db, store, remote_store), fields(%drv_path), err(level=tracing::Level::WARN))]
pub async fn substitute_output(
    db: db::Database,
    store: nix_utils::LocalStore,
    o: (nix_utils::OutputName, Option<StorePath>),
    build_id: BuildID,
    drv_path: &StorePath,
    remote_store: Option<&binary_cache::S3BinaryCacheClient>,
) -> anyhow::Result<bool> {
    let (name, path) = o;
    let Some(path) = path else {
        return Ok(false);
    };

    let starttime = i32::try_from(jiff::Timestamp::now().as_second())?; // TODO
    if let Err(e) = store.ensure_path(&path).await {
        tracing::debug!("Path not found, can't import={e}");
        return Ok(false);
    }
    if let Some(remote_store) = remote_store {
        let paths_to_copy = store
            .query_requisites(&[&path], false)
            .await
            .unwrap_or_default();
        let paths_to_copy = remote_store.query_missing_paths(paths_to_copy).await;
        if let Err(e) = remote_store.copy_paths(&store, paths_to_copy, false).await {
            tracing::error!(
                "Failed to copy paths to remote store({}): {e}",
                remote_store.cfg.client_config.bucket
            );
        }
    }
    let stoptime = i32::try_from(jiff::Timestamp::now().as_second())?; // TODO

    let mut db = db.get().await?;
    let mut tx = db.begin_transaction().await?;
    tx.create_substitution_step(
        store.store_dir(),
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
