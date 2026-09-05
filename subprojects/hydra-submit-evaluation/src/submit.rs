//! Submitting one evaluation of one jobset.
//!
//! Fetch the inputs, decide whether they have been evaluated before, and if
//! not queue a build that will run `nix-eval-jobs` over them. That is where
//! this half ends: the evaluation is finished when that build is, and reading
//! it back is `hydra-process-evaluation`'s job.

use color_eyre::eyre::{self, WrapErr as _};
use sha2::{Digest as _, Sha256};

use crate::config::HydraConfig;
use crate::eval_build;
use crate::fetcher::InputFetcher;
use crate::inputs::{self, ConfiguredInput};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries::{self, NewEval};
use crate::scheduler::now;
use crate::store_paths::Availability;

/// What submitting produced.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// An evaluation was queued as a build.
    Scheduled { eval: i32, build: i32 },
}

/// Submit an evaluation, recording the outcome on the jobset either way.
pub(crate) async fn submit(
    db: &db::Database,
    config: &HydraConfig,
    available: &Availability,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let started = now();
    let mut conn = db.get().await?;
    let meta = queries::get_jobset_for_eval(&mut conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))?;

    let result = schedule(&mut conn, config, available, project, jobset, &meta, trace).await;

    match &result {
        Ok(_) => queries::record_checked(&mut conn, meta.id, started, now()).await?,
        Err(e) => {
            queries::record_failed(&mut conn, trace, meta.id, &format!("{e:#}"), started, now())
                .await?;
        }
    }
    result
}

async fn schedule(
    conn: &mut db::Connection,
    config: &HydraConfig,
    available: &Availability,
    project: &str,
    jobset: &str,
    meta: &queries::JobsetForEval,
    trace: &str,
) -> eyre::Result<Outcome> {
    // Fetching is the slow part and the part that talks to the world, so it
    // happens before anything is written and outside any transaction.
    let checkout_start = std::time::Instant::now();
    let configured: Vec<ConfiguredInput> = queries::get_jobset_inputs(conn, project, jobset)
        .await?
        .into_iter()
        .map(|row| ConfiguredInput {
            name: row.name,
            r#type: row.r#type,
            value: row.value,
            email_responsible: row.emailresponsible != 0,
        })
        .collect();

    let mut fetcher = InputFetcher::start()?;
    let resolved =
        inputs::resolve(conn, &mut fetcher, available, project, jobset, &configured).await;
    fetcher.shutdown().await;
    let resolved = resolved?;
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
    let hash = format!("{:x}", Sha256::digest(cmd.join(" ").as_bytes()));
    if let Some(previous) = queries::get_previous_eval(conn, meta.id).await?
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && meta.flake.as_deref() == previous.flake.as_deref()
    {
        queries::notify_eval_cached(conn, trace, meta.id, previous.id).await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    let name = format!("{project}:{jobset}");
    let store_dir = available.store_dir().to_path().display().to_string();
    let drv_path =
        eval_build::instantiate(config, &resolved, "nix-eval-jobs", &cmd, &name, &store_dir)
            .await
            .wrap_err("failed to instantiate the evaluation derivation")?;

    let eval_jobset = queries::ensure_eval_jobset(conn).await?;
    let system = current_system().await?;

    let mut tx = conn.begin_transaction().await?;
    let build =
        queries::insert_eval_build(&mut tx, eval_jobset, &name, &drv_path, &system, now()).await?;
    let eval = queries::insert_eval(
        &mut tx,
        &NewEval {
            jobset_id: meta.id,
            checkout_time: i32::try_from(checkout_time).unwrap_or(0),
            hash: &hash,
            flake: meta.flake.as_deref(),
            nix_expr_input: meta.nixexprinput.as_deref(),
            nix_expr_path: meta.nixexprpath.as_deref(),
            eval_build: build,
            trace_id: trace,
        },
        now(),
    )
    .await?;

    // The inputs are recorded now because this is when they are known:
    // completion happens later, and re-fetching could see other revisions.
    for (name, alts) in &resolved {
        for (n, alt) in alts.iter().enumerate() {
            queries::insert_eval_input(
                &mut tx,
                eval,
                name,
                i32::try_from(n).unwrap_or(0),
                alt,
                &store_dir,
            )
            .await?;
        }
    }
    tx.commit().await?;

    Ok(Outcome::Scheduled { eval, build })
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
