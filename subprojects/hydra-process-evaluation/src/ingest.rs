//! Turning the jobs an evaluation found into builds.
//!
//! This is the half of an evaluation that touches no plugins: by the time a
//! job arrives there are no inputs left to fetch, only the question of
//! whether this job is already built and, if not, queueing it.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

use color_eyre::eyre::{self, WrapErr as _};

use crate::jobs::Job;
use crate::queries::{self, EvalToComplete, NewBuild, PreviousEval};

/// What happened to one job of an evaluation.
///
/// Every job becomes a member of the evaluation whether or not it caused a
/// build, which is what makes an evaluation a complete record of its jobs
/// rather than only of the new work it created.
#[derive(Debug)]
pub(crate) struct Member {
    pub(crate) build: i32,
    pub(crate) job: String,
    /// Whether this evaluation queued the build, as opposed to finding it
    /// already present from a previous one.
    pub(crate) is_new: bool,
    /// The derivation this evaluation says the job has, which may differ from
    /// the one the existing build was queued with.
    pub(crate) drv_path: String,
    /// Set when an existing build's derivation has changed underneath it.
    pub(crate) repoint: bool,
}

/// Decide what to do about one job, queueing a build if it is new.
///
/// Returns `None` when the job is a duplicate within this same evaluation --
/// two attributes producing the same output path -- which is not an error and
/// not a second build.
async fn check_build<'j>(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    eval: i32,
    job: &'j Job,
    prev_eval: Option<i32>,
    seen: &mut HashSet<String>,
    outputs: &mut queries::NewOutputs<'j>,
) -> eyre::Result<Option<Member>> {
    let drv_path = job
        .drv_path
        .as_deref()
        .ok_or_else(|| eyre::eyre!("job `{}` has no derivation", job.attr))?;
    eyre::ensure!(!job.attr.is_empty(), "a job has no name");

    // Any one output will do for the comparisons below: if one matches the
    // others will too, since they come from the same derivation. A
    // content-addressed output has no path yet, and is matched by derivation.
    let (first_name, first_path) = job
        .outputs
        .iter()
        .next()
        .ok_or_else(|| eyre::eyre!("job `{}` has no outputs", job.attr))?;

    // Already built, or already queued and still current for this job? Then
    // this evaluation inherits it rather than queueing another.
    //
    // Note what this means when a jobset's sources go from A to B and back to
    // A: three builds, not two. That is deliberate -- the highest build id
    // must be the one that ends up in the channel.
    if let Some(prev_eval) = prev_eval {
        let previous = queries::find_build_in_eval(
            tx,
            prev_eval,
            jobset_id,
            &job.attr,
            first_name,
            first_path.as_deref(),
            drv_path,
        )
        .await?;

        if let Some(previous) = previous {
            // Same output, different derivation: the build stands, but it
            // should be pointed at the derivation this evaluation found.
            // Applied after the evaluation's transaction, so that Builds rows
            // are not locked for its whole duration.
            let repoint = previous.drvpath != drv_path;

            if previous.finished != 0 && !repoint {
                tx.notify_cached_build_finished(eval, previous.id).await?;
            } else {
                tx.notify_cached_build_queued(eval, previous.id).await?;
            }

            return Ok(Some(Member {
                build: previous.id,
                job: job.attr.clone(),
                is_new: false,
                drv_path: drv_path.to_owned(),
                repoint,
            }));
        }
    }

    // Two attributes in this same evaluation producing the same output are
    // one build, not two.
    let key = format!(
        "{}\t{}",
        job.attr,
        first_path.as_deref().unwrap_or(drv_path)
    );
    if seen.contains(&key) {
        return Ok(None);
    }

    let meta = &job.meta;
    let build = queries::insert_build(
        tx,
        &NewBuild {
            jobset_id,
            job: &job.attr,
            drv_path,
            system: job.system.as_deref().unwrap_or_default(),
            nix_name: job.name.as_deref().or(meta.name.as_deref()),
            description: meta.description.as_deref(),
            license: meta.license.as_deref(),
            homepage: meta.homepage.as_deref(),
            maintainers: meta.maintainers.as_deref(),
            max_silent: meta.max_silent,
            timeout: meta.timeout,
            priority: meta.priority,
            is_channel: meta.is_channel,
        },
        crate::complete::now(),
    )
    .await
    .wrap_err_with(|| format!("failed to queue a build for `{}`", job.attr))?;

    for (name, path) in &job.outputs {
        outputs.builds.push(build);
        outputs.names.push(name);
        outputs.paths.push(path.as_deref());
    }

    seen.insert(key);
    tx.notify_build_queued(build).await?;

    Ok(Some(Member {
        build,
        job: job.attr.clone(),
        is_new: true,
        drv_path: drv_path.to_owned(),
        repoint: false,
    }))
}

/// What [`record`] wrote.
#[derive(Debug)]
pub(crate) struct Recorded {
    pub(crate) jobset_changed: bool,
    /// Builds inherited from an earlier evaluation whose derivation has
    /// changed, to be pointed at the new one once this transaction is done.
    pub(crate) repoints: HashMap<i32, String>,
}

/// Everything an evaluation records, including the jobset's new error, in
/// the caller's transaction.
///
/// One transaction, because an evaluation's builds, members, aggregates and
/// the notifications announcing them must be written together or not at all.
/// The notifications are sent from here for the same reason, since `NOTIFY`
/// is delivered on commit.
pub(crate) async fn record(
    tx: &mut db::Transaction<'_>,
    eval: &EvalToComplete,
    eval_id: i32,
    jobs: &[Job],
    previous: Option<PreviousEval>,
) -> eyre::Result<Recorded> {
    let jobset_id = eval.jobset_id;
    let prev_eval = previous.map(|p| p.id);

    // `.jobsets` is Hydra evaluating its own configuration, and is allowed
    // exactly one job.
    let jobsets_jobset =
        eval.declfile.as_deref().is_some_and(|f| !f.is_empty()) && eval.jobset_name == ".jobsets";
    if jobsets_jobset && jobs.iter().any(|job| job.attr != "jobsets") {
        eyre::bail!("The .jobsets jobset must only have a single job named 'jobsets'");
    }

    let mut error = String::new();
    let mut members: Vec<Member> = Vec::new();
    let mut seen = HashSet::new();
    let mut outputs = queries::NewOutputs::default();

    for job in jobs {
        // A job that failed to evaluate is reported but not built. The
        // evaluation still happened; this is what it found.
        if let Some(message) = &job.error {
            let where_ = if job.attr.is_empty() {
                "at top-level".to_owned()
            } else {
                format!("in job ‘{}’", job.attr)
            };
            let _ = write!(error, "{where_}:\n{message}\n\n");
        } else if let Some(member) = check_build(
            tx,
            jobset_id,
            eval_id,
            job,
            prev_eval,
            &mut seen,
            &mut outputs,
        )
        .await?
        {
            members.push(member);
        }
    }
    if !outputs.builds.is_empty() {
        queries::insert_build_outputs(tx, &outputs).await?;
    }

    // Did this evaluation change anything? Either it queued something, or the
    // set of jobs is a different size than last time -- a job disappearing is
    // a change even though it queues nothing.
    let queued = members.iter().any(|m| m.is_new);
    let jobset_changed = queued
        || previous.is_some_and(|p| i64::try_from(members.len()).is_ok_and(|n| n != p.members));

    let nr_builds = i32::try_from(members.len()).ok();
    queries::finish_eval(
        tx,
        eval_id,
        jobset_changed,
        jobset_changed.then_some(nr_builds).flatten(),
    )
    .await?;
    let error_changed =
        queries::set_jobset_error(tx, jobset_id, &error, crate::complete::now()).await?;
    tx.notify_eval_added(
        eval.trace_id.as_deref().unwrap_or_default(),
        jobset_id,
        eval_id,
        error_changed,
    )
    .await?;

    if jobset_changed {
        let rows: Vec<(i32, bool)> = members.iter().map(|m| (m.build, m.is_new)).collect();
        queries::insert_eval_members(tx, eval_id, &rows).await?;
        record_aggregates(tx, &members, jobs).await?;
        // What wakes the queue runner: it polls otherwise.
        if queued {
            tx.notify_builds_added().await?;
        }
    }

    if let Some(error_id) = eval.evaluationerror_id
        && !error.is_empty()
    {
        queries::set_evaluation_error(tx, error_id, &error).await?;
    }

    let repoints = members
        .iter()
        .filter(|m| m.repoint)
        .map(|m| (m.build, m.drv_path.clone()))
        .collect();

    Ok(Recorded {
        jobset_changed,
        repoints,
    })
}

/// Link each aggregate to its constituents.
///
/// Jobs can alias one another, so several may share a derivation. When they
/// do, the shortest name wins -- ties broken alphabetically -- so that an
/// aggregate points at the most canonical of them rather than an arbitrary
/// one.
async fn record_aggregates(
    tx: &mut db::Transaction<'_>,
    members: &[Member],
    jobs: &[Job],
) -> eyre::Result<()> {
    let mut by_drv: HashMap<&str, &Member> = HashMap::new();
    for member in members {
        match by_drv.get(member.drv_path.as_str()) {
            Some(existing)
                if (existing.job.len(), existing.job.as_str())
                    <= (member.job.len(), member.job.as_str()) => {}
            _ => {
                by_drv.insert(&member.drv_path, member);
            }
        }
    }

    for job in jobs {
        let Some(constituents) = &job.constituents else {
            continue;
        };

        // An aggregate that did not evaluate cannot be assembled, and
        // silently producing a partial one would be worse than failing.
        if let Some(message) = &job.error {
            eyre::bail!(
                "aggregate job ‘{}’ failed with the error: {message}",
                job.attr
            );
        }

        let drv = job.drv_path.as_deref().unwrap_or_default();
        let aggregate = by_drv.get(drv).ok_or_else(|| {
            eyre::eyre!(
                "aggregate job ‘{}’ has no corresponding build record.",
                job.attr
            )
        })?;

        for constituent_drv in constituents {
            if let Some(constituent) = by_drv.get(constituent_drv.as_str()) {
                queries::insert_aggregate_constituent(tx, aggregate.build, constituent.build)
                    .await?;
            } else {
                tracing::debug!(
                    "aggregate job ‘{}’ has a constituent ‘{constituent_drv}’ \
                     that doesn't correspond to a Hydra build",
                    job.attr
                );
            }
        }
    }

    Ok(())
}
