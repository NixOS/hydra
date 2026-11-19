//! Turning the jobs an evaluation found into builds.
//!
//! This is the half of an evaluation that touches no plugins: by the time a
//! job arrives there are no inputs left to fetch, only the question of
//! whether this job is already built and, if not, queueing it.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

use color_eyre::eyre::{self, WrapErr as _};

use crate::nix_eval_jobs::Job;
use crate::queries;
use crate::queries::NewBuild;

/// What happened to one job of an evaluation.
///
/// Every job becomes a member of the evaluation whether or not it caused a
/// build, which is what makes an evaluation a complete record of its jobs
/// rather than only of the new work it created.
#[derive(Debug)]
pub(crate) struct Member {
    pub build: i32,
    pub job: String,
    /// Whether this evaluation queued the build, as opposed to finding it
    /// already present from a previous one.
    pub is_new: bool,
    /// The derivation this evaluation says the job has, which may differ from
    /// the one the existing build was queued with.
    pub drv_path: String,
    /// Set when an existing build's derivation has changed underneath it.
    pub repoint: bool,
}

/// The previous evaluation's build outputs by job, loaded in one query, to
/// find the builds this evaluation inherits.
struct Previous(HashMap<String, Vec<queries::PreviousOutput>>);

impl Previous {
    async fn load(
        tx: &mut db::Transaction<'_>,
        eval: Option<i32>,
        jobset_id: i32,
    ) -> eyre::Result<Self> {
        let mut by_job: HashMap<String, Vec<queries::PreviousOutput>> = HashMap::new();
        if let Some(eval) = eval {
            for mut output in queries::get_eval_outputs(tx, eval, jobset_id).await? {
                by_job
                    .entry(std::mem::take(&mut output.job))
                    .or_default()
                    .push(output);
            }
        }
        Ok(Self(by_job))
    }

    /// The build of this job matched on its first output's path, or on the
    /// derivation when there is no path yet.
    fn find(
        &self,
        job: &str,
        output_name: &str,
        output_path: Option<&str>,
        drv_path: &str,
    ) -> Option<&queries::PreviousOutput> {
        self.0.get(job)?.iter().find(|o| {
            o.name == output_name
                && match output_path {
                    Some(path) => o.path.as_deref() == Some(path),
                    None => o.drvpath == drv_path,
                }
        })
    }
}

/// What an evaluation found, gathered so it can be written in bulk.
#[derive(Default)]
struct Found<'j> {
    /// Members inheriting a build from the previous evaluation.
    inherited: Vec<Member>,
    /// Builds to queue, each a new member once it has an id.
    new: Vec<NewBuild<'j>>,
    /// Inherited builds, still to be built and already finished.
    cached_queued: Vec<i32>,
    cached_finished: Vec<i32>,
}

impl Found<'_> {
    /// Queue the new builds and announce every build, returning all members.
    async fn write(
        self,
        tx: &mut db::Transaction<'_>,
        jobset_id: i32,
        eval_id: i32,
    ) -> eyre::Result<Vec<Member>> {
        let ids = queries::insert_builds(tx, jobset_id, &self.new)
            .await
            .wrap_err("failed to queue the evaluation's builds")?;
        tx.notify_builds_queued(&ids).await?;
        tx.notify_cached_builds_queued(eval_id, &self.cached_queued)
            .await?;
        tx.notify_cached_builds_finished(eval_id, &self.cached_finished)
            .await?;
        let mut members = self.inherited;
        members.extend(self.new.iter().zip(ids).map(|(b, build)| Member {
            build,
            job: b.job.to_owned(),
            is_new: true,
            drv_path: b.drv_path.to_owned(),
            repoint: false,
        }));
        Ok(members)
    }
}

/// Decide what to do about one job: inherit a build from the previous
/// evaluation, or queue a new one.
///
/// Two attributes in this same evaluation producing the same output are one
/// build, so a job already in `seen` is skipped.
fn check_build<'j>(
    found: &mut Found<'j>,
    seen: &mut HashSet<String>,
    previous: &Previous,
    job: &'j Job,
) -> eyre::Result<()> {
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
    if let Some(prev) = previous.find(&job.attr, first_name, first_path.as_deref(), drv_path) {
        // Same output, different derivation: the build stands, but it
        // should be pointed at the derivation this evaluation found.
        // Applied after the evaluation's transaction, so that Builds rows
        // are not locked for its whole duration.
        let repoint = prev.drvpath != drv_path;

        if prev.finished != 0 && !repoint {
            found.cached_finished.push(prev.id);
        } else {
            found.cached_queued.push(prev.id);
        }

        found.inherited.push(Member {
            build: prev.id,
            job: job.attr.clone(),
            is_new: false,
            drv_path: drv_path.to_owned(),
            repoint,
        });
        return Ok(());
    }

    let key = format!(
        "{}\t{}",
        job.attr,
        first_path.as_deref().unwrap_or(drv_path)
    );
    if !seen.insert(key) {
        return Ok(());
    }

    let meta = &job.meta;
    found.new.push(NewBuild {
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
        outputs: &job.outputs,
    });
    Ok(())
}

/// What [`record`] wrote.
pub(crate) struct Recorded {
    pub eval: i32,
    pub jobset_changed: bool,
    /// Builds inherited from an earlier evaluation whose derivation has
    /// changed, to be pointed at the new one once this transaction is done.
    pub repoints: HashMap<i32, String>,
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
    trace: &str,
    eval: &queries::NewEval<'_>,
    jobs: &[Job],
    prev_eval: Option<i32>,
    inputs: &crate::inputs::InputInfo,
    store_dir: &db::StoreDir,
) -> eyre::Result<Recorded> {
    let jobset_id = eval.jobset_id;
    let error_time = jiff::Timestamp::now().as_second();
    let error_id = queries::insert_evaluation_error(tx, error_time).await?;
    let eval_id = queries::insert_eval(tx, eval, error_id).await?;

    let mut error = String::new();
    let mut found = Found::default();
    let previous = Previous::load(tx, prev_eval, jobset_id).await?;
    let mut seen = HashSet::new();
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
        } else {
            check_build(&mut found, &mut seen, &previous, job)?;
        }
    }
    drop(previous);

    let members = found.write(tx, jobset_id, eval_id).await?;

    // Did this evaluation change anything? Either it queued something, or the
    // set of jobs is a different size than last time -- a job disappearing is
    // a change even though it queues nothing.
    let queued = members.iter().any(|m| m.is_new);
    let jobset_changed = queued
        || match prev_eval {
            Some(prev) => {
                i64::try_from(members.len()).ok()
                    != Some(queries::count_eval_members(tx, prev).await?)
            }
            None => false,
        };

    let nr_builds = i32::try_from(members.len()).ok();
    queries::finish_eval(
        tx,
        eval_id,
        jobset_changed,
        jobset_changed.then_some(nr_builds).flatten(),
    )
    .await?;
    queries::finish_jobset_eval(tx, jobset_id).await?;
    let error_changed = queries::set_jobset_error(tx, jobset_id, &error, error_time).await?;
    tx.notify_eval_added(trace, jobset_id, eval_id, error_changed)
        .await?;

    if jobset_changed {
        let rows: Vec<(i32, bool)> = members.iter().map(|m| (m.build, m.is_new)).collect();
        queries::insert_eval_members(tx, eval_id, &rows).await?;
        record_aggregates(tx, &members, jobs).await?;
        // What wakes the queue runner: it polls otherwise.
        if queued {
            tx.notify_builds_added().await?;
        }

        for (name, alts) in inputs {
            for (n, alt) in alts.iter().enumerate() {
                queries::insert_eval_input(
                    tx,
                    eval_id,
                    name,
                    i32::try_from(n).unwrap_or(0),
                    alt,
                    store_dir,
                )
                .await?;
            }
        }
    }

    if !error.is_empty() {
        queries::set_evaluation_error(tx, error_id, &error).await?;
    }

    let repoints = members
        .iter()
        .filter(|m| m.repoint)
        .map(|m| (m.build, m.drv_path.clone()))
        .collect();

    Ok(Recorded {
        eval: eval_id,
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
