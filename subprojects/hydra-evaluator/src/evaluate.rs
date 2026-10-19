//! Evaluating one jobset, end to end.
//!
//! Fetch the inputs, decide whether they have been evaluated before, run
//! `nix-eval-jobs` over them, and record what it found. The pieces live in
//! their own modules; this is the order they happen in and the decisions
//! between them.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};
use sha2::{Digest as _, Sha256};

use crate::config::HydraConfig;
use crate::declarative;
use crate::eval_build;
use crate::fetcher::InputFetcher;
use crate::ingest;
use crate::inputs::{self, ConfiguredInput, InputInfo};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries;
use crate::queries::NewEval;

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// What evaluating a jobset produced.
#[derive(Debug, Clone, Copy)]
pub enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// An evaluation was scheduled as a build; it is finished when that
    /// build is, not now.
    Scheduled { eval: i32, build: i32 },
    /// A declarative project whose specification named its jobsets outright,
    /// so they were created and there was nothing to evaluate.
    Declared,
}

#[allow(clippy::too_many_lines)]
pub async fn evaluate(
    db: &db::Database,
    config: &HydraConfig,
    available: &crate::store_paths::Availability,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let mut conn = db.get().await?;
    let meta = queries::get_jobset_for_eval(&mut conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;

    // One worker fetches every plugin input this evaluation needs, the
    // declarative specification's included.
    let mut fetcher = InputFetcher::start()?;

    // `.jobsets` is Hydra evaluating a declarative project's own
    // configuration. The specification may name the jobsets outright, in
    // which case they are created and this is done; or it may describe how
    // to generate them, in which case it reconfigures this jobset, which is
    // then evaluated with the specification's input and the project's name
    // besides its own.
    let mut extra_inputs = InputInfo::new();
    let mut extra_configured = Vec::new();
    if let Some(declfile) = meta.declfile.as_deref().filter(|f| !f.is_empty())
        && jobset == ".jobsets"
    {
        let decl = ConfiguredInput {
            name: "declInput".to_owned(),
            r#type: meta.decltype.clone().unwrap_or_default(),
            value: meta.declvalue.clone(),
            email_responsible: false,
        };
        extra_inputs =
            inputs::resolve(&mut conn, &mut fetcher, available, project, jobset, &[decl]).await?;
        let [decl_input] = extra_inputs["declInput"].as_slice() else {
            eyre::bail!(
                "the input containing the declarative project specification must have \
                 exactly one alternative"
            );
        };
        let store_path = decl_input.store_path.as_deref().unwrap_or_default();
        let spec_file = format!(
            "{}/{declfile}",
            nix_eval_jobs::full(available.store_dir(), store_path)
        );
        if declarative::apply(project, &spec_file).await? {
            fetcher.shutdown().await;
            // The specification was applied, so any error from a previous
            // attempt at it is over: `Some("")` clears it.
            queries::update_jobset_after_eval(&mut conn, meta.id, Some(""), now()).await?;
            return Ok(Outcome::Declared);
        }
        extra_configured.push(ConfiguredInput {
            name: "projectName".to_owned(),
            r#type: "string".to_owned(),
            value: Some(project.to_owned()),
            email_responsible: false,
        });
    }
    // Re-read, since a specification may have changed what to evaluate.
    let meta = queries::get_jobset_for_eval(&mut conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;

    conn.notify_eval_started(trace, meta.id).await?;

    // Fetching is the slow part and the part that talks to the world, so it
    // happens before anything is written and outside any transaction.
    let checkout_start = std::time::Instant::now();
    let configured: Vec<ConfiguredInput> = queries::get_jobset_inputs(&mut conn, project, jobset)
        .await?
        .into_iter()
        .map(|row| ConfiguredInput {
            name: row.name,
            r#type: row.r#type,
            value: row.value,
            email_responsible: row.emailresponsible != 0,
        })
        .chain(extra_configured)
        .collect();

    let resolved = inputs::resolve(
        &mut conn,
        &mut fetcher,
        available,
        project,
        jobset,
        &configured,
    )
    .await;
    let mut resolved = resolved?;
    resolved.extend(extra_inputs);
    let checkout_time = checkout_start.elapsed().as_secs();

    let expr = Expression {
        flake: meta.flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };
    let cmd = nix_eval_jobs::command(available.store_dir(), config, &resolved, &expr)?;

    // The hash covers the arguments, so it changes exactly when what would be
    // evaluated changes. If the previous evaluation used the same ones there
    // is nothing to learn by running it again.
    let hash = hex::encode(Sha256::digest(cmd.join(" ").as_bytes()));
    let previous = queries::get_previous_eval(&mut conn, meta.id).await?;

    if let Some(previous) = &previous
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && meta.flake.as_deref() == previous.flake.as_deref()
    {
        fetcher.shutdown().await;
        tracing::info!("({project}:{jobset}) already evaluated these inputs");
        conn.notify_eval_cached(trace, meta.id, previous.id).await?;
        queries::update_jobset_after_eval(&mut conn, meta.id, None, now()).await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    // Evaluation happens in a build, so that it is scheduled and distributed
    // like any other work. Scheduling it ends this run: the evaluation is
    // finished when that build completes, not here.
    tracing::info!("({project}:{jobset}) scheduling the evaluation as a build");

    let drv_path = eval_build::instantiate(
        config,
        &resolved,
        &cmd,
        &format!("{project}:{jobset}"),
        &available.store_dir().to_path().display().to_string(),
    )
    .await
    .wrap_err("failed to instantiate the evaluation derivation")?;

    let eval_jobset = queries::ensure_eval_jobset(&mut conn).await?;
    let system = current_system().await?;

    let mut tx = conn.begin_transaction().await?;
    let build = queries::insert_eval_build(
        &mut tx,
        eval_jobset,
        &format!("{project}:{jobset}"),
        &drv_path,
        &system,
        now(),
    )
    .await?;

    // A tentative evaluation, pointing at the build that will fill it in. It
    // exists from the start so the evaluation is visible while it runs;
    // `hasnewbuilds` is a placeholder until then, and `completed` is left
    // null to say so.
    let error_id = queries::insert_evaluation_error(&mut tx, now()).await?;
    let eval_id = queries::insert_eval(
        &mut tx,
        &NewEval {
            jobset_id: meta.id,
            checkout_time: i32::try_from(checkout_time).unwrap_or(0),
            hash: &hash,
            flake: meta.flake.as_deref(),
            nix_expr_input: meta.nixexprinput.as_deref(),
            nix_expr_path: meta.nixexprpath.as_deref(),
            evaluation_error_id: Some(error_id),
            eval_build: Some(build),
            trace_id: Some(trace),
        },
    )
    .await?;

    // The inputs are recorded here rather than when the evaluation finishes,
    // because this is where they are known: completing it happens later, and
    // re-fetching could see different revisions than the ones evaluated.
    for (name, alts) in &resolved {
        for (n, alt) in alts.iter().enumerate() {
            queries::insert_eval_input(
                &mut tx,
                eval_id,
                name,
                i32::try_from(n).unwrap_or(0),
                alt,
                &available.store_dir().to_path().display().to_string(),
            )
            .await?;
        }
    }

    tx.commit().await?;

    // The plugins add a temp root for each path they fetch, but those roots
    // belong to the worker and last only as long as it does. Keep it until
    // the evaluation derivation, which refers to the inputs, is queued.
    fetcher.shutdown().await;

    queries::update_jobset_after_eval(&mut conn, meta.id, None, now()).await?;

    Ok(Outcome::Scheduled {
        eval: eval_id,
        build,
    })
}

/// The system the evaluation build should be scheduled for.
async fn current_system() -> eyre::Result<String> {
    let out = tokio::process::Command::new("nix-instantiate")
        .args(["--eval", "-E", "builtins.currentSystem"])
        .output()
        .await
        .wrap_err("could not ask nix for the current system")?;
    eyre::ensure!(
        out.status.success(),
        "could not ask nix for the current system"
    );
    Ok(String::from_utf8_lossy(&out.stdout)
        .trim()
        .trim_matches('"')
        .to_owned())
}

/// Read a finished evaluation build's output back, and turn its jobs into
/// builds of the jobset that was evaluated.
pub async fn complete(db: &db::Database, config: &HydraConfig, eval_id: i32) -> eyre::Result<()> {
    let mut conn = db.get().await?;
    let Some(eval) = queries::get_eval_to_complete(&mut conn, eval_id).await? else {
        return Ok(());
    };
    let trace = eval.trace_id.clone().unwrap_or_default();

    // A build that failed evaluated nothing; the error is the build's, and its
    // log is where it is explained.
    if eval.build_status.unwrap_or(1) != 0 {
        queries::update_jobset_after_eval(
            &mut conn,
            eval.jobset_id,
            Some("evaluation failed; see the evaluation build's log"),
            now(),
        )
        .await?;
        let mut tx = conn.begin_transaction().await?;
        queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
        tx.commit().await?;
        return Ok(());
    }

    let path = eval
        .out_path
        .ok_or_else(|| eyre::eyre!("evaluation build {eval_id} produced no output"))?;
    let jobs = nix_eval_jobs::read(&path).await?;

    // What this evaluation is compared against: the jobs of the evaluation
    // before it, so a job already built is not built again, and its member
    // count, since a job disappearing changes the jobset while queueing
    // nothing.
    let previous = queries::get_eval_before(&mut conn, eval.jobset_id, eval_id).await?;
    let prev_member_count = match &previous {
        Some(p) => Some(queries::count_eval_members(&mut conn, p.id).await?),
        None => None,
    };

    let meta = queries::get_jobset_for_completion(&mut conn, eval.jobset_id)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset {} does not exist", eval.jobset_id))?;

    // `.jobsets` is Hydra evaluating its own configuration, and is allowed
    // exactly one job.
    let jobsets_jobset =
        meta.declfile.as_deref().is_some_and(|f| !f.is_empty()) && meta.name == ".jobsets";

    let mut tx = conn.begin_transaction().await?;
    let error_id = queries::insert_evaluation_error(&mut tx, now()).await?;
    let recorded = ingest::record(
        &mut tx,
        eval.jobset_id,
        &trace,
        eval_id,
        error_id,
        meta.errormsg.as_deref().unwrap_or_default(),
        &jobs,
        previous.as_ref().map(|p| p.id),
        prev_member_count,
        // Already recorded when the evaluation was scheduled, which is where
        // the inputs were known; the store directory is only for those.
        &InputInfo::new(),
        "",
        jobsets_jobset,
    )
    .await
    .wrap_err("failed to record the evaluation")?;
    queries::mark_eval_completed(&mut tx, eval_id, now()).await?;
    tx.commit().await?;

    // Root every job's derivation, not only those that became builds: an
    // aggregate is reported as a job and nothing else in the store refers to
    // its derivation. This is what `nix-eval-jobs --gc-roots-dir` did for
    // `hydra-eval-jobs`.
    if let Err(e) = add_roots(
        config.roots_dir(),
        jobs.iter().filter_map(|j| j.drv_path.as_deref()),
    ) {
        tracing::warn!("could not root the evaluated derivations: {e:#}");
    }

    // Both of these touch every build of the jobset, so they run afterwards:
    // holding those row locks for the evaluation's duration deadlocks against
    // the queue runner finishing builds.
    if recorded.jobset_changed {
        queries::mark_current(&mut conn, eval.jobset_id, eval_id, CURRENT_BATCH)
            .await
            .wrap_err("failed to mark this evaluation's builds current")?;
    }

    repoint(&mut conn, &recorded.repoints)
        .await
        .wrap_err("failed to repoint builds at their new derivations")?;

    queries::update_jobset_after_eval(&mut conn, eval.jobset_id, Some(&recorded.error), now())
        .await?;

    Ok(())
}

/// Symlink each derivation into Hydra's roots directory -- the same one the
/// queue runner uses, so `hydra-update-gc-roots` knows to tidy it.
fn add_roots<'a>(
    configured: Option<&std::path::Path>,
    drvs: impl Iterator<Item = &'a str>,
) -> eyre::Result<()> {
    let dir = if let Some(dir) = configured {
        dir.to_owned()
    } else {
        let remote = daemon_client_utils::parse_nix_remote()
            .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
        let logname = std::env::var("LOGNAME").wrap_err("LOGNAME is not set")?;
        remote
            .state_dir
            .join("gcroots/per-user")
            .join(logname)
            .join("hydra-roots")
    };
    fs_err::create_dir_all(&dir)?;
    for drv in drvs {
        let Some(name) = std::path::Path::new(drv).file_name() else {
            continue;
        };
        match fs_err::os::unix::fs::symlink(drv, dir.join(name)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e).wrap_err_with(|| format!("rooting {drv}")),
        }
    }
    Ok(())
}

fn now() -> db::Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}

/// Apply the derivation changes an evaluation found for builds it inherited.
///
/// Separate from the evaluation transaction for the same reason as
/// `mark_current`: these are `Builds` rows the queue runner also writes.
async fn repoint(conn: &mut db::Connection, repoints: &HashMap<i32, String>) -> eyre::Result<()> {
    let mut ids: Vec<&i32> = repoints.keys().collect();
    ids.sort_unstable();
    for id in ids {
        queries::repoint_build(conn, *id, &repoints[id]).await?;
    }
    Ok(())
}
