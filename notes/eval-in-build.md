Design: evaluation as a build
=============================

Status: implemented, and the only way evaluation happens -- there is no toggle back to the old path.
This is the detail behind step 4 of the recursive-Nix roadmap (`roadmap-recursive-nix.md`, kept outside the branch).

Evaluating a jobset stops being something the evaluator *does* and becomes something it *schedules*: one Hydra build per evaluation, running `nix-eval-jobs`, dispatched to a builder like any other build.
Evaluation then inherits sandboxing, timeouts, retries, logs and distribution, instead of all evaluation competing for the Hydra host.

What each component does
------------------------

`hydra-submit-evaluation` decides which jobsets are due, and for each one:

- fetches the jobset's inputs and materializes them as store paths, applying a declarative project's specification first when the jobset is `.jobsets`
- hashes the `nix-eval-jobs` arguments; if the jobset's latest evaluation has the same hash, stops here
- instantiates the evaluation derivation
- queues the evaluation build, and creates the `JobsetEval` row pointing at it with `eval_build`, together with its `JobsetEvalInputs`.
  The inputs are recorded here because this is where they are known: the evaluation is processed later, by another program, and re-fetching could see a newer revision than the one evaluated.
- returns.
  It does not wait: the queue runner dispatches builds, and blocking would tie the submitter to a build that may sit in the queue for hours.

`hydra-process-evaluation` waits for `build_finished`, and catches up at startup on anything that finished while it was not running.
For a finished evaluation build it:

- reads the jobs from the build's *output*, the JSONL `nix-eval-jobs` wrote
- fills in the evaluation that already exists rather than making a second one, creating the builds, members and aggregates
- roots every job's derivation (see below)
- sets `completed`, which is what stops it looking at the evaluation again

A failed evaluation build is recorded as a failed evaluation: it is completed, and the jobset gets the error.

The builder and the queue runner learn nothing: an evaluation build is a build.

Why two programs
----------------

The two halves are not separated by a process boundary.
They are separated by a *time* boundary: the evaluation build can take hours and outlive any restart of either side.
So what connects them has to be durable and re-derivable from the database, whoever owns it -- which is why `eval_build`, `completed` and `trace_id` are columns.
A long-lived worker could not keep an evaluation's context in memory across that gap, and would not want to.

Once that is accepted, the halves have nothing in common but the rows.
One talks to input plugins, the store and `nix-instantiate`; the other to a JSONL file and the builds table.
The plugin boundary falls exactly on that split: input types are only reached while fetching, which only submission does.
Splitting the queries by which half runs them found two in common, and both were wrong for one side or the other, so the two are separate crates sharing no code.

Why the hash check comes first
------------------------------

`JobsetEvals.hash` already prevents re-evaluating unchanged inputs: a jobset whose hash matches is skipped, and no `JobsetEval` row is created.
That is the common case for a jobset polled on `checkInterval` with nothing changed.

If the evaluation build were created before that check, every poll of an unchanged jobset would manufacture a build, and evaluation counts, `keepnr` and the jobset overview would all shift.
The inputs must be materialized before the derivation can be instantiated anyway, so the hash is in hand at exactly the right moment: fetch, hash, skip or proceed.

`JobsetEvals.hash` therefore remains the deduplication mechanism, with the derivation cache behind it as a second layer.
The two can legitimately disagree -- the hash covers `nix-eval-jobs` arguments, the derivation covers input store paths.

The latest evaluation counts whatever became of it.
One still running is right to count, since the same inputs are on their way; one whose build failed is not, and is an open question below.

Evaluation writes to the store
------------------------------

Evaluation instantiates derivations: the `.drv` files `nix-eval-jobs` reports are created as it goes, and Hydra cannot build them later unless they are in the real store.
A build sandbox has a read-only store view, so a way to add paths back out is needed before any question of builds *during* evaluation arises.

Recursive Nix's store-write half is exactly that, and it is already in the pinned Nix (2.35-maintenance): `RestrictedStore::addToStore` and `addToStoreFromDump` forward to the underlying store and call `goal.addDependency()` on the new path.
No permission check, no experimental gate beyond `recursive-nix` itself, and no involvement of content-addressed derivations.

This is separable from builds during evaluation, and the roadmap's ordering is wrong about it.
Nested builds are a different surface on the same class -- `buildPaths`, `buildPathsWithResults`, `ensurePath` -- and they are where the special handling lives: stock recursive Nix satisfies a nested build request locally, on the builder, which is precisely what Hydra does not want.
Evaluation as a build needs only `addToStore` and `addToStoreFromDump`, with `buildPaths` left refusing.
So it does not depend on recursive Nix reaching the queue runner; that is a prerequisite for builds during evaluation, not for evaluation in a build.

Verified on stock Nix 2.35 rather than taken on faith: a sandboxed derivation with `requiredSystemFeatures = [ "recursive-nix" ]` running `nix store add-path` does add the path, and it is valid in the outer store once the build finishes.
That holds against a *relocated* store (`local?root=…`), so the worry that a relocated store forces a chroot recursive Nix cannot live with is unfounded.
`sandbox-build-dir must not contain the storeDir` only bites when the store is genuinely underneath the build directory.

Two conditions, both ones Hydra already has to satisfy for its own tooling: the store's *logical* directory has to be the one the paths are named with, and whatever the build runs -- Nix itself included -- has to be in that store rather than merely on the host.

The second is why the Perl test suite does not exercise this path.
The harness gives its store a logical directory under the test's temporary directory, so no `/nix/store` path is addressable there, and the evaluation build runs unsandboxed with an explicit `evaluation_build_store_uri` instead.
That is a property of the harness, not of the design, but it does mean the production path is not covered by a test.

`nix-eval-jobs` is used unmodified, talking to the recursive-Nix daemon socket like any other client.
The build script is only

    set -eu; export HOME="$PWD"; "$@" > "$out"

and `eval_build.rs` says, beside each line of the derivation, what the build lacks that a process on the coordinator got for free.

Rooting the evaluated derivations
---------------------------------

Retention was expected to fall out of the reference graph: the JSONL contains `/nix/store/…-foo.drv` strings, so reference scanning records those derivations as references of `$out`, and rooting the evaluation build's output would root every derivation it names.
That does not hold in practice -- aggregate derivations were collectable immediately after evaluation -- so the roots are made explicitly.

`nix-eval-jobs --gc-roots-dir` cannot make them any more: the directory is outside the sandbox, and a build cannot write to it.
`hydra-process-evaluation` makes them instead, from the derivations the JSONL names, in `roots_dir` -- the directory `hydra-update-gc-roots` tidies.
It reads `evaluator.toml` for that setting and nothing else.

Every job needs a root, not only the jobs that become builds: an aggregate is reported as a job and nothing else in the store refers to its derivation.
Worth revisiting whether the reference-graph argument can be made to work, since it would make retention automatic rather than a step that can be forgotten.

Gathering the inputs
--------------------

The inputs go *into* the evaluation derivation rather than being fetched by it.
Hydra already had what that needs: the fetchers ran ahead of evaluation, and `JobsetEvalInputs` records per input its `type`, `uri`, `revision`, `value`, `dependency` and -- the one that matters -- `path`, the materialized store path.
What changed is where those paths are handed to: an instantiation instead of a command line.

A consequence worth stating plainly: `--restrict-eval` stops being load-bearing.
It was the security boundary while evaluation ran unsandboxed on the Hydra host.
When evaluation is a sandboxed build, the sandbox enforces that structurally -- the evaluation can only see what is in the derivation -- and restricted eval becomes defence in depth at most.

Where evaluation builds live
----------------------------

In their own jobset, `hydra:evaluations`, not in the jobset being evaluated.
`Builds` needs a non-null `jobset_id`, and the honest answer is "none of them".
Keeping them out of the evaluated jobset also keeps them out of its build listings and success statistics, where they would appear as a job nothing in the jobset names.

That jobset must be disabled.
The scheduler takes enabled jobsets of enabled projects, so an enabled evaluation jobset would be scheduled for evaluation itself -- and evaluating it would want to create an evaluation build in itself.
Excluding it by construction beats a special case someone can flip in the UI.

Retention deserves a deliberate answer rather than the default: this one jobset accumulates a build per evaluation across the whole instance, so it grows with jobsets times poll frequency.

The schema
----------

Migration 89 adds three nullable columns to `JobsetEvals`, all metadata-only, so nothing is rewritten and `JobsetEvalMembers` -- a row per build per evaluation, the table you least want to migrate -- is untouched:

- `eval_build`, the build performing the evaluation.
- `completed`, when its result was read back.
  `evalTime` and `hasNewBuilds` are `not null` but unknown until then, so a tentative row carries placeholders, and `completed` is what distinguishes a placeholder from an answer.
  It is also what says which evaluations still need reading back.
  That cannot be inferred: a build finishing and its result being consumed are separate events, and an evaluation may legitimately find no jobs.
- `trace_id`, so the evaluation's notifications are traced to the submission that started it.

`eval_build` is `ON DELETE SET NULL`, never cascade.
Evaluation builds live in a high-churn jobset that will be garbage collected aggressively; a cascading delete would remove the `JobsetEval` an aged-out build produced.
Losing the provenance while keeping the evaluation is the right failure mode, and `evaluationerror_id` already uses `on delete set null` for the same reason.

The reference is to the build, not to a build step.
With builds during evaluation the evaluation build has several steps and there is no stable "the" step to name; the build is the unit that *is* the evaluation.

Because evaluation builds are not members of the evaluation they produce, `JobsetEvalMembers` continues to mean exactly "the jobs of this evaluation".

What the evaluator no longer does
---------------------------------

Supervising a long evaluation in-process went with the evaluation:

- `max_concurrent_evals`, killing the evaluation of a removed jobset, and reaping.
  Build scheduling is by builder capacity and system features.
- The in-memory copy of every jobset, re-read on each notification, and the arithmetic deciding how long to sleep.
  One query asks the database which jobsets are due, including the one-at-a-time rule, and the loop wakes on a jobset event, a finished submission, or a short timer.
- `jobsets.startTime` as a lock, `--unlock`, and the `ExecStopPost` that called it.
  A build is queued or running, and a crash leaves no jobset wedged.
  Nothing sets the column any more.
- Measuring how long evaluating took.
  The build knows; `JobsetEvals.evalTime` is written as 0.
  The column stays: it is the only record of how long evaluations took before this, so dropping it waits until nothing reads the old values.

The two columns are still there, as are the pages that read them.
The jobset page's "evaluation running since" never appears; the duration it gives the last evaluation is only how long fetching its inputs took; and an evaluation's page says evaluating took 0s.

On the way, `forceEval` is now reset once the evaluation it forced is submitted.
Neither the Perl nor the first Rust evaluator did, so one forced evaluation made every later one skip the cache.

Interaction with builds during evaluation
-----------------------------------------

Once step 3 of the roadmap lands, a build requested *during* an evaluation becomes a step of the evaluation build, not a separate build.
Hydra normally derives a build's steps from the derivation's input closure, known at queue time, and a dependency discovered mid-evaluation is by definition not in it -- but `create_build_step` allocates `stepnr` dynamically, so appending a step to an in-flight build is already mechanically supported.

If that holds, `JobsetEvalMembers.forEvaluation` (the `ifd-awareness` branch) may become unnecessary: it exists to mark a member as "a build the evaluation needed rather than a job", and steps are not members.
Worth settling before that branch lands, since it is a migration on the largest table.

Not done, and why
-----------------

- **Seeing the jobs before the evaluation finishes.**
  The design this grew from had the evaluation write its JSONL to a stream as well as to `$out`, relayed by the builder and persisted by the queue runner the way it persists logs.
  It is a separate feature with its own protocol change, so it is not on this branch.
  What was established for it, and is cheap to get wrong again:
  a FIFO bound into the sandbox with `--option extra-sandbox-paths "/hydra-stream=$somewhere/stream"` is writable from inside a build on stock Nix, since Linux exempts FIFOs from the read-only-mount check in `may_open`, and `extra-sandbox-paths` is accepted from a trusted user on the command line, unlike `system-features`.
  The builder should stay a dumb relay, never parsing the format, which belongs to `nix-eval-jobs`.
  And the stream can only ever be a preview: if the evaluation derivation was built before, nothing runs and nothing is streamed, so `$out` stays the answer.
- **Folding the `eval_added`/`eval_failed`/`eval_cached` channels into `build_finished`.**
  It looks right but races: the queue runner sends `build_finished` for the evaluation build before `hydra-process-evaluation` has ingested its output, so a plugin woken by it would read the jobset before its error is written.
  Collapsing the three into one `eval_finished`, sent by `hydra-process-evaluation` after it commits, would delete the `error_changed` flag and two of the three `Hydra::Event::Eval*` classes without that race.
  Not done, since it removes a feature merged in #1886 for a saving of a few hundred lines.
- **Evaluation limits as build limits.**
  `evaluator_max_memory_size` and the evaluation timeout could give way to `builds.timeout` and `builds.maxsilent`, now that an evaluation is a build.

Open questions
--------------

- A failed evaluation build still counts as evaluating its inputs.
  The submitter compares against the latest evaluation whatever became of it, so after a failure the same inputs are not tried again until they change or someone forces it.
  A transient failure -- a builder lost mid-build -- then sticks.
  The Perl version deleted the tentative evaluation on failure; that, or skipping failed evaluations in the comparison, would fix it.
- An evaluation in flight is not listed.
  Every listing filters on `hasNewBuilds`, which reads the placeholder `0` as "finished, found nothing" and hides the evaluation for exactly as long as it is interesting.
- What assumes a build's step set is complete when it is queued?
  Progress display, the dispatcher's notion of what is runnable, and anything computing "steps remaining" are the likely candidates.
- Scheduling and priority: the evaluation build holds a slot while its nested builds run.
  This must not deadlock.
- What this does *not* obsolete.
  Input fetching still writes to the coordinator's store, and the queue runner still reads `.drv` files from it, so the submitter still guards the coordinator's free disk.
  That goes when the coordinator stops having a store at all: inputs fetched by the builder, results uploaded to the cache, `.drv` files fetched back from it to be run.
  That is the change this one is a prerequisite for, and the honest measure of whether the approach is right.
- Evaluation that fetches has no network in a sandbox.
  Pre-fetching every input is the principled answer.
- Retention of the evaluations jobset.
- How much of `nix-eval-jobs` survives when evaluation is a build?

Nix changes we are deliberately not making
------------------------------------------

Everything above works on stock Nix 2.35; `recursive-nix` needs enabling in the daemon's `experimental-features` and `system-features`, but that is configuration, not a patch.
Two Nix changes would make this nicer:

- A first-class extra output stream from a build, so nothing has to be bind-mounted into the sandbox to get bytes out.
  The builder receives only what the daemon reports as log messages, which is why the stream above needed a FIFO.
- Routing `RestrictedStore::buildPaths` back to the queue runner instead of satisfying it locally on the builder.
  That is what builds during evaluation will need, and it is the only part of recursive Nix that requires work -- the store-write half is already enough for evaluation itself.
