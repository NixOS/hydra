use db::Transaction;
use db::models::BuildID;
use nix_utils::BaseStore as _;

use crate::state::RemoteBuild;

#[tracing::instrument(skip(tx, res), err)]
pub async fn finish_build_step(
    tx: &mut Transaction<'_>,
    build_id: BuildID,
    step_nr: i32,
    res: &RemoteBuild,
    machine: Option<String>,
) -> anyhow::Result<()> {
    debug_assert!(res.start_time.is_some());
    debug_assert!(res.stop_time.is_some());
    tx.update_build_step_in_finish(db::models::UpdateBuildStepInFinish {
        build_id,
        step_nr,
        status: res.step_status,
        error_msg: res.error_msg.as_deref(),
        start_time: i32::try_from(res.start_time.map(|s| s.timestamp()).unwrap_or_default())?,
        stop_time: i32::try_from(res.stop_time.map(|s| s.timestamp()).unwrap_or_default())?,
        machine: machine.as_deref(),
        overhead: if res.overhead != 0 {
            Some(res.overhead)
        } else {
            None
        },
        times_built: if res.times_build > 0 {
            Some(res.times_build)
        } else {
            None
        },
        is_non_deterministic: if res.times_build > 0 {
            Some(res.is_non_deterministic)
        } else {
            None
        },
    })
    .await?;
    debug_assert!(!res.log_file.is_empty());
    debug_assert!(!res.log_file.contains('\t'));

    tx.notify_step_finished(build_id, step_nr, &res.log_file)
        .await?;

    if res.step_status == db::models::BuildStatus::Success {
        // Update the corresponding `BuildStepOutputs` row to add the output path
        let drv_path = tx.get_drv_path_from_build_step(build_id, step_nr).await?;
        if let Some(drv_path) = drv_path {
            // If we've finished building, all the paths should be known
            if let Some(drv) = nix_utils::query_drv(&nix_utils::StorePath::new(&drv_path)).await? {
                for o in drv.outputs {
                    if let Some(path) = o.path {
                        tx.update_build_step_output(
                            build_id,
                            step_nr,
                            &o.name,
                            &path.get_full_path(),
                        )
                        .await?;
                    }
                }
            }
        }
    }
    Ok(())
}

#[tracing::instrument(skip(db, store, o, build_opts, remote_store), fields(%drv_path), err(level=tracing::Level::WARN))]
pub async fn substitute_output(
    db: db::Database,
    store: nix_utils::LocalStore,
    o: nix_utils::DerivationOutput,
    build_id: BuildID,
    drv_path: &nix_utils::StorePath,
    build_opts: &nix_utils::BuildOptions,
    remote_store: Option<&nix_utils::RemoteStore>,
) -> anyhow::Result<()> {
    let Some(path) = &o.path else {
        return Ok(());
    };

    let starttime = i32::try_from(chrono::Utc::now().timestamp())?; // TODO
    let (mut child, _) = nix_utils::realise_drv(path, build_opts, false).await?;
    nix_utils::validate_statuscode(child.wait().await?)?;
    if let Some(remote_store) = remote_store {
        let paths_to_copy = store
            .query_requisites(vec![path.to_owned()], false)
            .await
            .unwrap_or_default();
        let paths_to_copy = remote_store.query_missing_paths(paths_to_copy).await;
        nix_utils::copy_paths(
            store.as_base_store(),
            remote_store.as_base_store(),
            &paths_to_copy,
            false,
            true,
            false,
        )
        .await?;
    }
    let stoptime = i32::try_from(chrono::Utc::now().timestamp())?; // TODO

    let mut db = db.get().await?;
    let mut tx = db.begin_transaction().await?;
    tx.create_substitution_step(
        starttime,
        stoptime,
        build_id,
        &drv_path.get_full_path(),
        (o.name, o.path.map(|p| p.get_full_path())),
    )
    .await?;
    tx.commit().await?;

    Ok(())
}
