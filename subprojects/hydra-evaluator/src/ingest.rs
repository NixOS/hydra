//! Turning the jobs an evaluation found into builds.
//!
//! This is the half of an evaluation that touches no plugins: by the time a
//! job arrives there are no inputs left to fetch, only the question of
//! whether this job is already built and, if not, queueing it.

use std::collections::HashMap;

use color_eyre::eyre::{self, WrapErr as _};

use crate::nix_eval_jobs::Job;
use crate::queries;
use crate::queries::NewBuild;

/// What happened to one job of an evaluation.
///
/// Every job becomes a member of the evaluation whether or not it caused a
/// build, which is what makes an evaluation a complete record of its jobs
/// rather than only of the new work it created.
#[derive(Debug, Clone)]
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

/// Decide what to do about one job, queueing a build if it is new.
///
/// Returns `None` when the job is a duplicate within this same evaluation --
/// two attributes producing the same output path -- which is not an error and
/// not a second build.
pub(crate) async fn check_build(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    eval: i32,
    job: &Job,
    prev_eval: Option<i32>,
    seen: &mut HashMap<String, i32>,
) -> eyre::Result<Option<Member>> {
    let drv_path = job
        .drv_path
        .as_deref()
        .ok_or_else(|| eyre::eyre!("job `{}` has no derivation", job.attr))?;
    eyre::ensure!(!job.attr.is_empty(), "a job has no name");
    eyre::ensure!(!job.outputs.is_empty(), "job `{}` has no outputs", job.attr);

    // Any one output will do for the comparisons below: if one matches the
    // others will too, since they come from the same derivation.
    let (first_name, first_path) = job
        .outputs
        .iter()
        .next()
        .map(|(n, p)| (n.clone(), p.clone()))
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
            &first_name,
            Some(first_path.as_str()),
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
    let key = format!("{}\t{first_path}", job.attr);
    if seen.contains_key(&key) {
        return Ok(None);
    }

    let meta = Meta::of(job);
    let build = queries::insert_build(
        tx,
        &NewBuild {
            jobset_id,
            job: &job.attr,
            drv_path,
            system: job.system.as_deref().unwrap_or_default(),
            nix_name: meta.name.as_deref(),
            description: meta.description.as_deref(),
            license: meta.license.clone(),
            homepage: meta.homepage.as_deref(),
            maintainers: meta.maintainers.clone(),
            max_silent: meta.max_silent,
            timeout: meta.timeout,
            priority: meta.priority,
            is_channel: meta.is_channel,
        },
    )
    .await
    .wrap_err_with(|| format!("failed to queue a build for `{}`", job.attr))?;

    let outputs: Vec<(String, String)> = job
        .outputs
        .iter()
        .map(|(n, p)| (n.clone(), p.clone()))
        .collect();
    queries::insert_build_outputs(tx, build, &outputs).await?;

    seen.insert(key, build);
    tx.notify_build_queued(build).await?;

    Ok(Some(Member {
        build,
        job: job.attr.clone(),
        is_new: true,
        drv_path: drv_path.to_owned(),
        repoint: false,
    }))
}

/// The parts of a job's `meta` that Hydra records.
///
/// All optional: a jobset may set none of them, and a missing or empty value
/// means "not stated" rather than "empty string".
#[derive(Debug, Default)]
struct Meta {
    name: Option<String>,
    description: Option<String>,
    license: Option<String>,
    homepage: Option<String>,
    maintainers: Option<String>,
    max_silent: Option<i32>,
    timeout: Option<i32>,
    priority: i32,
    is_channel: i32,
}

impl Meta {
    fn of(job: &Job) -> Self {
        let meta = job.meta.as_ref();
        let get = |key: &str| meta.and_then(|m| m.get(key));

        Self {
            name: nonempty(get("name").and_then(as_string)),
            description: nonempty(get("description").and_then(as_string)),
            // `license` and `maintainers` are lists of attribute sets in
            // nixpkgs and bare strings elsewhere, so both are flattened to a
            // comma-separated list of one field.
            license: concat_strings(get("license"), "shortName"),
            homepage: nonempty(get("homepage").and_then(as_string)),
            maintainers: concat_strings(get("maintainers"), "email"),
            max_silent: get("maxSilent").and_then(as_int),
            timeout: get("timeout").and_then(as_int),
            priority: get("schedulingPriority").and_then(as_int).unwrap_or(100),
            is_channel: i32::from(
                get("isChannel")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
            ),
        }
    }
}

fn as_string(v: &serde_json::Value) -> Option<String> {
    v.as_str().map(str::to_owned)
}

fn as_int(v: &serde_json::Value) -> Option<i32> {
    v.as_i64().and_then(|n| i32::try_from(n).ok())
}

fn nonempty(s: Option<String>) -> Option<String> {
    s.filter(|s| !s.is_empty())
}

/// Flatten a `meta` value that may be a string, a list, or a list of
/// attribute sets, taking `key` from each set.
fn concat_strings(value: Option<&serde_json::Value>, key: &str) -> Option<String> {
    let mut out = Vec::new();
    collect_strings(value, key, &mut out);
    if out.is_empty() {
        None
    } else {
        Some(out.join(", "))
    }
}

fn collect_strings(value: Option<&serde_json::Value>, key: &str, out: &mut Vec<String>) {
    match value {
        Some(serde_json::Value::Object(map)) => {
            if let Some(v) = map.get(key).and_then(serde_json::Value::as_str) {
                out.push(v.to_owned());
            }
        }
        Some(serde_json::Value::Array(items)) => {
            for item in items {
                collect_strings(Some(item), key, out);
            }
        }
        Some(serde_json::Value::String(s)) => out.push(s.clone()),
        Some(v) if !v.is_null() => out.push(v.to_string()),
        _ => {}
    }
}

/// Everything an evaluation records, in one transaction.
///
/// One transaction because an evaluation is one fact: its builds, its
/// members, its aggregates and the notifications announcing them are true
/// together or not at all. It is also why the notifications are sent from in
/// here -- `NOTIFY` is delivered on commit.
pub(crate) struct Recorded {
    pub eval: i32,
    pub jobset_changed: bool,
    pub error: String,
    /// Builds inherited from an earlier evaluation whose derivation has
    /// changed, to be pointed at the new one once this transaction is done.
    pub repoints: HashMap<i32, String>,
}

pub(crate) async fn record(
    tx: &mut db::Transaction<'_>,
    jobset_id: i32,
    trace: &str,
    eval: &queries::NewEval<'_>,
    error_id: i32,
    prev_error: &str,
    jobs: &[Job],
    prev_eval: Option<i32>,
    prev_member_count: Option<i64>,
    inputs: &crate::inputs::InputInfo,
    jobsets_jobset: bool,
) -> eyre::Result<Recorded> {
    let eval_id = queries::insert_eval(tx, eval).await?;

    let mut error = String::new();
    let mut members: Vec<Member> = Vec::new();
    let mut seen = HashMap::new();
    let mut with_constituents: Vec<&Job> = Vec::new();

    for job in jobs {
        if jobsets_jobset {
            eyre::ensure!(
                job.attr == "jobsets",
                "The .jobsets jobset must only have a single job named 'jobsets'"
            );
        }

        // A job that failed to evaluate is reported but not built. The
        // evaluation still happened; this is what it found.
        if let Some(message) = &job.error {
            let where_ = if job.attr.is_empty() {
                "at top-level".to_owned()
            } else {
                format!("in job `{}'", job.attr)
            };
            error.push_str(&format!("{where_}:\n{message}\n\n"));
        } else if let Some(member) =
            check_build(tx, jobset_id, eval_id, job, prev_eval, &mut seen).await?
        {
            members.push(member);
        }

        if job.constituents.is_some() {
            with_constituents.push(job);
        }
    }

    // Did this evaluation change anything? Either it queued something, or the
    // set of jobs is a different size than last time -- a job disappearing is
    // a change even though it queues nothing.
    let jobset_changed = members.iter().any(|m| m.is_new)
        || prev_member_count.is_some_and(|n| n != members.len() as i64);

    let nr_builds = i32::try_from(members.len()).ok();
    queries::finish_eval(
        tx,
        eval_id,
        jobset_changed,
        jobset_changed.then_some(nr_builds).flatten(),
    )
    .await?;
    // The jobset's error is not written until after this transaction commits,
    // so `prev_error` is still the one it had coming in.
    queries::notify_eval_added(tx, trace, jobset_id, eval_id, error != prev_error).await?;

    if jobset_changed {
        let rows: Vec<(i32, bool)> = members.iter().map(|m| (m.build, m.is_new)).collect();
        queries::insert_eval_members(tx, eval_id, &rows).await?;
        record_aggregates(tx, &members, &with_constituents).await?;

        for (name, alts) in inputs {
            for (n, alt) in alts.iter().enumerate() {
                queries::insert_eval_input(tx, eval_id, name, i32::try_from(n).unwrap_or(0), alt)
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
        error,
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
    with_constituents: &[&Job],
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

    for job in with_constituents {
        let Some(constituents) = &job.constituents else {
            continue;
        };

        // An aggregate that did not evaluate cannot be assembled, and
        // silently producing a partial one would be worse than failing.
        if let Some(message) = &job.error {
            eyre::bail!(
                "aggregate job `{}' failed with the error: {message}",
                job.attr
            );
        }

        let drv = job.drv_path.as_deref().unwrap_or_default();
        let aggregate = by_drv.get(drv).ok_or_else(|| {
            eyre::eyre!(
                "aggregate job `{}' has no corresponding build record.",
                job.attr
            )
        })?;

        for constituent_drv in constituents {
            match by_drv.get(constituent_drv.as_str()) {
                Some(constituent) => {
                    queries::insert_aggregate_constituent(tx, aggregate.build, constituent.build)
                        .await?;
                }
                None => tracing::warn!(
                    "aggregate job `{}' has a constituent `{constituent_drv}' \
                     that doesn't correspond to a Hydra build",
                    job.attr
                ),
            }
        }
    }

    Ok(())
}
