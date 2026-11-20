//! Evaluating one jobset, end to end.
//!
//! Fetch the inputs, decide whether they have been evaluated before, run
//! `nix-eval-jobs` over them, and record what it found. The pieces live in
//! their own modules; this is the order they happen in and the decisions
//! between them.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};
use futures::FutureExt as _;

use crate::config::HydraConfig;
use crate::declarative;
use crate::fetcher::InputFetcher;
use crate::ingest;
use crate::inputs::{self, ConfiguredInput, InputInfo};
use crate::nix_eval_jobs::{self, Expression};
use crate::queries;
use crate::queries::{JobsetForEval, NewEval};

/// How many rows to move at a time when marking builds current.
const CURRENT_BATCH: i32 = 10_000;

/// What evaluating a jobset produced.
#[derive(Debug)]
pub(crate) enum Outcome {
    /// These inputs had been evaluated before, so nothing was done.
    Cached { previous: i32 },
    /// The evaluation ran and was recorded.
    Evaluated {
        eval: i32,
        changed: bool,
        followup: Followup,
    },
    /// A declarative project whose specification named its jobsets outright,
    /// so they were created and there was nothing to evaluate.
    Declared,
    /// An input could not be fetched. The error goes in the jobset's fetch
    /// error, and its evaluation error stays as it was.
    FetchFailed,
}

impl Outcome {
    /// Whether `hydra-evaluator <project> <jobset>` should exit successfully.
    pub(crate) fn succeeded(&self) -> bool {
        !matches!(self, Self::FetchFailed)
    }
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cached { previous } => write!(f, "cached, same as evaluation {previous}"),
            Self::Evaluated {
                eval,
                changed: true,
                ..
            } => write!(f, "added evaluation {eval}"),
            Self::Evaluated {
                eval,
                changed: false,
                ..
            } => write!(f, "evaluation {eval} found no changes"),
            Self::Declared => f.write_str("jobsets created from the declarative specification"),
            Self::FetchFailed => f.write_str("could not fetch its inputs"),
        }
    }
}

/// What is left to do to the jobset's builds once an evaluation is recorded.
///
/// It runs outside the evaluation transaction, because holding these row
/// locks that long deadlocks against the queue runner. It also runs after the
/// evaluation frees its slot, because on a large jobset it takes minutes.
///
/// It keeps the connection the evaluation was recorded on, rather than
/// taking others from the pool.
///
/// Committing the evaluation creates two obligations, met here:
///
/// - Repointing: the inherited builds whose derivation changed get the new
///   one and are queued again. Once the evaluation is committed, the new
///   derivations are recorded nowhere durable, only in [`Self::repoints`].
///
/// - Marking current: `iscurrent` comes to match membership in the current
///   evaluation. That is derivable from durable state at any time, so any
///   later `mark_current` of the jobset settles it completely.
///
/// Neither depends on the other, so a failure of one does not skip the other.
///
/// Meeting them is best effort. If this fails, or never runs because the
/// evaluator stopped, the database is still consistent, just stale: builds
/// not repointed keep their old derivation and state, including a failure
/// that would otherwise have been retried, and `iscurrent` lags. The next
/// evaluation of the jobset that is not cached derives both obligations again
/// and meets them. One that is cached has no follow-up, so until the jobset's
/// inputs change, nothing does.
#[derive(Debug)]
pub(crate) struct Followup {
    conn: db::Connection,
    jobset_id: i32,
    /// Inherited builds whose derivation changed.
    repoints: HashMap<i32, String>,
    /// The evaluation whose builds are now current.
    current: Option<i32>,
}

impl Followup {
    /// Both obligations are attempted. The caller records a failure as the
    /// jobset's evaluation error; if both fail, that is the repointing one,
    /// and the other is logged.
    pub(crate) async fn run(self) -> eyre::Result<()> {
        let Self {
            conn,
            jobset_id,
            repoints,
            current,
        } = self;
        let repoints = &repoints;

        let start = std::time::Instant::now();
        let (conn, repointed) = retry("repointing builds", conn, |mut conn| async move {
            let result = repoint(&mut conn, repoints).await;
            (conn, result)
        })
        .await;
        let repointed = repointed.wrap_err("failed to repoint builds at their new derivations");
        if repointed.is_ok() {
            tracing::info!(
                "repointed {} builds in {} s",
                repoints.len(),
                start.elapsed().as_secs()
            );
        }

        let marked = match current {
            Some(current) => {
                let start = std::time::Instant::now();
                let (_, marked) = retry("marking builds current", conn, |mut conn| async move {
                    let result =
                        queries::mark_current(&mut conn, jobset_id, current, CURRENT_BATCH)
                            .await
                            .map_err(Into::into);
                    (conn, result)
                })
                .await;
                let marked = marked.wrap_err("failed to mark this evaluation's builds current");
                if marked.is_ok() {
                    tracing::info!(
                        "marked evaluation {current}'s builds current in {} s",
                        start.elapsed().as_secs()
                    );
                }
                marked
            }
            None => Ok(()),
        };

        match (repointed, marked) {
            (Err(e), Err(also)) => {
                tracing::warn!("{also:#}");
                Err(e)
            }
            (Err(e), Ok(())) | (Ok(()), Err(e)) => Err(e),
            (Ok(()), Ok(())) => Ok(()),
        }
    }
}

#[allow(clippy::too_many_lines)]
pub(crate) async fn evaluate(
    db: &db::Database,
    config: &HydraConfig,
    available: &crate::store_paths::Availability,
    roots_dir: &std::path::Path,
    project: &str,
    jobset: &str,
    trace: &str,
) -> eyre::Result<Outcome> {
    let mut conn = db.get().await?;
    let meta = get_jobset(&mut conn, project, jobset).await?;

    conn.notify_eval_started(trace, meta.id).await?;

    // One worker fetches every plugin input this evaluation needs, the
    // declarative specification's included.
    let mut fetcher = InputFetcher::new(&available.programs().fetch_input);

    // `.jobsets` is Hydra evaluating a declarative project's own
    // configuration. The specification may name the jobsets outright, in
    // which case they are created and this is done; or it may describe how
    // to generate them, in which case it reconfigures this jobset, which is
    // then evaluated with the specification's input and the project's name
    // besides its own.
    let jobsets_jobset =
        jobset == ".jobsets" && meta.declfile.as_deref().is_some_and(|f| !f.is_empty());
    let mut extra_inputs = InputInfo::new();
    let mut extra_configured = Vec::new();
    if jobsets_jobset {
        let declfile = meta.declfile.as_deref().unwrap_or_default();
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
        if declarative::apply(
            &available.programs().prepare_declarative_jobset,
            project,
            &spec_file,
        )
        .await?
        {
            fetcher.shutdown().await;
            let mut tx = conn.begin_transaction().await?;
            queries::set_jobset_error(&mut tx, meta.id, "", jiff::Timestamp::now().as_second())
                .await?;
            tx.commit().await?;
            return Ok(Outcome::Declared);
        }
        extra_configured.push(ConfiguredInput {
            name: "projectName".to_owned(),
            r#type: "string".to_owned(),
            value: Some(project.to_owned()),
            email_responsible: false,
        });
    }
    // Re-read, since the specification may have changed what to evaluate.
    let meta = if jobsets_jobset {
        get_jobset(&mut conn, project, jobset).await?
    } else {
        meta
    };

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

    let resolution = inputs::resolve(
        &mut conn,
        &mut fetcher,
        available,
        project,
        jobset,
        &configured,
    )
    .await;

    // Lock the flake so the evaluation runs on, and records, one fixed
    // revision. As in the Perl, a flake that cannot be locked fails the
    // evaluation even when an input also failed to fetch.
    let flake = match meta.flake.as_deref() {
        Some(flake) => Some(lock_flake(&available.programs().nix, flake).await?),
        None => None,
    };
    let checkout_time = checkout_start.elapsed().as_secs();

    let mut resolved = match resolution {
        Ok(resolved) => resolved,
        Err(e) => {
            fetcher.shutdown().await;
            let message = format!("{e:#}");
            let mut tx = conn.begin_transaction().await?;
            queries::set_fetch_error(&mut tx, meta.id, Some(&message)).await?;
            // A fetch error leaves `errormsg` unchanged, so the notification
            // says the error did not change and nobody is mailed.
            tx.notify_eval_failed(trace, meta.id, false).await?;
            tx.commit().await?;
            return Ok(Outcome::FetchFailed);
        }
    };
    resolved.extend(extra_inputs);

    let expr = Expression {
        flake: flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };
    let hash = nix_eval_jobs::input_hash(available.store_dir(), &resolved, &expr)?;

    if let Some(previous) = queries::get_latest_eval(&mut conn, meta.id).await?
        && previous.hash == hash
        && !meta.forceeval.unwrap_or(false)
        && (flake.is_none() || previous.flake == flake)
    {
        fetcher.shutdown().await;
        tracing::info!("already evaluated these inputs");
        let mut tx = conn.begin_transaction().await?;
        queries::set_fetch_error(&mut tx, meta.id, None).await?;
        tx.notify_eval_cached(trace, meta.id, previous.id).await?;
        tx.commit().await?;
        return Ok(Outcome::Cached {
            previous: previous.id,
        });
    }

    // Nothing needs the database while `nix-eval-jobs` runs, which can take
    // long enough that holding a pooled connection would starve the others.
    drop(conn);

    tracing::info!("evaluating");
    let cmd = nix_eval_jobs::command(available.store_dir(), config, &resolved, &expr)?;
    let eval_start = std::time::Instant::now();
    let jobs = nix_eval_jobs::run(&available.programs().nix_eval_jobs, &cmd, roots_dir).await?;
    let eval_time = eval_start.elapsed().as_secs();
    if jobsets_jobset && jobs.iter().any(|job| job.attr != "jobsets") {
        eyre::bail!("The .jobsets jobset must only have a single job named 'jobsets'");
    }

    // Compare jobs against the last evaluation that had new builds, because
    // an evaluation without new builds records no members.
    //
    // From here on one connection does the rest: the evaluation transaction,
    // and then the follow-up, which inherits it.
    let mut conn = db.get().await?;
    let previous = queries::get_previous_eval_with_new_builds(&mut conn, meta.id).await?;

    let new_eval = NewEval {
        jobset_id: meta.id,
        checkout_time: i32::try_from(checkout_time).unwrap_or(0),
        eval_time: i32::try_from(eval_time).unwrap_or(0),
        hash: &hash,
        flake: flake.as_deref(),
        nix_expr_input: meta.nixexprinput.as_deref(),
        nix_expr_path: meta.nixexprpath.as_deref(),
    };
    let ingest_start = std::time::Instant::now();
    let (new_eval, jobs, resolved) = (&new_eval, &jobs, &resolved);
    let prev_eval = previous.as_ref().map(|p| p.id);
    let (conn, recorded) = retry("the evaluation transaction", conn, |mut conn| async move {
        let result: eyre::Result<_> = async {
            let mut tx = conn.begin_transaction().await?;
            let recorded = ingest::record(
                &mut tx,
                trace,
                new_eval,
                jobs,
                prev_eval,
                resolved,
                available.store_dir(),
            )
            .await
            .wrap_err("failed to record the evaluation")?;
            tx.commit().await?;
            Ok(recorded)
        }
        .await;
        (conn, result)
    })
    .await;
    let recorded = recorded?;
    tracing::info!(
        "recorded {} jobs in {} s",
        jobs.len(),
        ingest_start.elapsed().as_secs()
    );

    // The plugins add a temp root for each path they fetch, but those roots
    // belong to the worker and last only as long as it does. Keep it until
    // evaluation is done with the inputs.
    fetcher.shutdown().await;

    // The current builds are this evaluation's if it changed anything, and
    // otherwise still those of the last one that did.
    let current = if recorded.jobset_changed {
        Some(recorded.eval)
    } else {
        previous.as_ref().map(|p| p.id)
    };

    Ok(Outcome::Evaluated {
        eval: recorded.eval,
        changed: recorded.jobset_changed,
        followup: Followup {
            conn,
            jobset_id: meta.id,
            repoints: recorded.repoints,
            current,
        },
    })
}

async fn get_jobset(
    conn: &mut db::Connection,
    project: &str,
    jobset: &str,
) -> eyre::Result<JobsetForEval> {
    queries::get_jobset_for_eval(conn, project, jobset)
        .await?
        .ok_or_else(|| eyre::eyre!("jobset `{project}:{jobset}' does not exist"))
}

/// Lock a flake reference with `nix flake metadata`, returning the locked
/// reference.
async fn lock_flake(nix: &hydra_programs::NixPath, flake: &str) -> eyre::Result<String> {
    #[derive(serde::Deserialize)]
    struct Metadata {
        url: String,
    }

    let out = crate::run_with_timeout(
        tokio::process::Command::new(nix)
            .args(["flake", "metadata", "--refresh", "--json", "--"])
            .arg(flake),
    )
    .await
    .wrap_err("failed to run 'nix flake metadata'")?;
    if !out.status.success() {
        let stderr = String::from_utf8(out.stderr)
            .wrap_err("'nix flake metadata' wrote non-UTF-8 to stderr")?;
        eyre::bail!(
            "'nix flake metadata' failed: {}:\n{}",
            out.status,
            if stderr.is_empty() {
                "(no output)"
            } else {
                &stderr
            }
        );
    }
    let metadata: Metadata = serde_json::from_slice(&out.stdout)
        .wrap_err("'nix flake metadata' sent unreadable JSON")?;
    Ok(metadata.url)
}

/// [`db::retry_serialization_failures_on`] for work that fails with an
/// [`eyre::Report`]. Each attempt must open its own transaction.
async fn retry<T, Fut>(
    what: &str,
    conn: db::Connection,
    mut work: impl FnMut(db::Connection) -> Fut,
) -> (db::Connection, eyre::Result<T>)
where
    Fut: Future<Output = (db::Connection, eyre::Result<T>)>,
{
    let (conn, result) = db::retry_serialization_failures_on(what, conn, |conn| {
        work(conn).map(|(conn, result)| (conn, result.map_err(Retryable)))
    })
    .await;
    (conn, result.map_err(|e| e.0))
}

/// An [`eyre::Report`] that is retryable when a database error in its chain
/// is.
struct Retryable(eyre::Report);

impl db::RetryableError for Retryable {
    fn is_retryable_serialization_failure(&self) -> bool {
        self.0.chain().any(|cause| {
            cause
                .downcast_ref::<db::Error>()
                .is_some_and(db::Error::is_retryable_serialization_failure)
                || cause
                    .downcast_ref::<sqlx::Error>()
                    .is_some_and(sqlx::Error::is_retryable_serialization_failure)
        })
    }
}

impl std::fmt::Display for Retryable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#}", self.0)
    }
}

/// Apply the derivation changes an evaluation found for builds it inherited,
/// in one transaction and in id order.
///
/// Separate from the evaluation transaction for the same reason as
/// `mark_current`: these are `Builds` rows the queue runner also writes.
async fn repoint(conn: &mut db::Connection, repoints: &HashMap<i32, String>) -> eyre::Result<()> {
    if repoints.is_empty() {
        return Ok(());
    }
    let mut ids: Vec<&i32> = repoints.keys().collect();
    ids.sort_unstable();
    let mut tx = conn.begin_transaction().await?;
    for id in ids {
        queries::repoint_build(&mut tx, *id, &repoints[id]).await?;
    }
    tx.commit().await?;
    Ok(())
}
