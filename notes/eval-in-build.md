Design: evaluation as a build
=============================

Status: implemented on this branch, and the only way evaluation
happens -- there is no toggle back to the old path. This is the detail
behind step 4 of `roadmap-recursive-nix.md`.

The parts that remain open are marked as such below; the ones settled
during implementation have been folded into the prose rather than left
as questions.

The idea is that evaluating a jobset stops being something the
`hydra-evaluator` service *does* and becomes something it *schedules*:
one Hydra build per evaluation, running `nix-eval-jobs`, dispatched to a
builder like any other build. Evaluation then inherits sandboxing,
timeouts, retries, logs, and distribution for free, instead of all
evaluation competing for the Hydra host.

What each component knows
-------------------------

Scheduler (`hydra-eval-jobset`, which no longer evaluates anything):

- fetch the jobset's inputs and materialize them as store paths
- hash the inputs; if the hash is already in `JobsetEvals`, stop here
- instantiate the evaluation derivation
- create the `JobsetEval` row, and its `JobsetEvalInputs` -- the inputs are
  recorded here because this is where they are known; the run that finishes
  the evaluation is a different process, and re-fetching could see a newer
  revision than the one actually evaluated
- queue the evaluation build and point `JobsetEvals.eval_build` at it
- return. It deliberately does not wait: the queue runner is what dispatches
  builds, so blocking would hold an evaluator slot for as long as the build
  sat in the queue

Finisher (`hydra-eval-jobset --finish-evaluation <id>`, run when the
evaluation build completes):

- read the jobs from the build's *output*
- fill in the evaluation that already exists, rather than making a second one
- on a failed evaluation build, delete the tentative evaluation. Leaving it
  would record its inputs hash as evaluated, and the jobset would never
  retry those inputs

Builder: gains exactly one capability, and it is not evaluation-shaped —
bind-mount a FIFO (or unix socket) at a fixed path in the build sandbox
via `extra-sandbox-paths`, and relay what comes out of it as an extra
*named* stream. `BuildLog` becomes the case where the name is the log.

This really is a new channel rather than "one more fd". The builder does
not read the build's file descriptors today: it calls `build_derivation`
over the nix daemon protocol and receives structured `LogMessage`s,
filtering `BuildLogLine` / `PostBuildLogLine` and forwarding those to
`build_log`. Nix hands it log lines, not an fd. So getting anything
*else* out of the sandbox needs a path into it — hence the bind-mount —
even though everything downstream of the builder should look exactly
like logs.

A FIFO suffices and works on a read-only bind mount: Linux exempts
FIFOs, sockets and devices from the read-only-mount write check in
`may_open`, so a build can open one for writing even where it cannot
write to the filesystem. A socket is the better choice if a build might
open the stream more than once.

Verified against stock Nix: a derivation built with

    --option extra-sandbox-paths "/hydra-stream=$somewhere/stream"

can `echo ... > /hydra-stream` and a reader outside the sandbox receives
the lines. `extra-sandbox-paths` is accepted from a trusted user on the
command line, unlike `system-features`, which the daemon reads only for
itself.

Queue runner: persists each stream the way it already persists the log,
keyed by name. It does not parse them and gains no eval vocabulary; it
also inherits whatever logs already do about retention, compression and
garbage collection.

Evaluator: the only component that knows what the bytes mean. It tails
the stream for liveness and reads `$out` for the authoritative result,
then writes `JobsetEvals` / `JobsetEvalMembers` / `Builds`.

This is deliberately the shape of the live-log websocket service (PR
1773): that service gets nothing pushed to it by the queue runner —
it reads metadata from Postgres, tails the log files the runner already
writes, and takes `NOTIFY` for completion. Following it means no new
queue-runner API at all, and a consumer pattern that already exists.

Treating the JSONL as its own named stream rather than folding it into
the build log also preserves a separation `nix-eval-jobs` already gives
us: jobs go to stdout, diagnostics to stderr, and a build log merges
them.

Note this is a preview and nothing more. The stream reaches the build
through `extra-sandbox-paths`, which binds nothing in an unsandboxed
build, so an unsandboxed evaluation produces no stream at all -- as does
one whose derivation was built before and so never ran. The evaluation
must complete identically either way, and does: `$out` is the answer and
the stream only ever makes the jobs visible sooner.

Why the builder stays a dumb relay
----------------------------------

It is tempting to have the builder parse the JSONL and send structured
results. Don't: the format belongs to `nix-eval-jobs`, which neither
Hydra component owns. A builder that parses it has to be redeployed
whenever that format moves, and during a rollout you get builders and
queue runner disagreeing about a schema that is not theirs.

Keeping the payload opaque also keeps the builder free of Hydra's data
model — `hydra-builder` has no `db` dependency today, and this should
not be the change that introduces one. Wrapping the JSON in a protobuf
envelope is fine; the envelope must stay an envelope. As soon as it
grows a `job_name` or a `drv_path` field, the builder has learned the
schema again.

Why the stream cannot be the source of truth
-----------------------------------------

The evaluation derivation is content-addressed like any other. If it has
been built before — substituted, or an identical evaluation ran earlier
— the builder never runs, and *nothing is ever streamed*. That is
correct and desirable (identical inputs, identical jobs), but it means
the stream is a latency optimization only.

So the derivation's output must be the complete JSONL, and the consumer
must handle both paths. Ideally the same consumer: a streaming path that
is a separate implementation of the parsing will drift from the
output-reading path, and the drift will only show up on cache hits.

Why the hash check comes first
------------------------------

`JobsetEvals.hash` already prevents re-evaluating unchanged inputs, and
the schema is explicit that a jobset whose hash is already present is
*skipped* — no `JobsetEval` row is created at all. That is the common
case for a jobset polled on `checkInterval` with nothing changed.

If the evaluation build were created before that check, every poll of an
unchanged jobset would manufacture a build, and eval counts, `keepnr`
and the jobset overview would all shift. The inputs must be materialized
before the derivation can be instantiated anyway, so the hash is in hand
at exactly the right moment: fetch, hash, skip-or-proceed.

Note this means `JobsetEvals.hash` remains the deduplication mechanism;
the derivation cache sits behind it as a second layer. The two can
legitimately disagree — the hash covers `nix-eval-jobs` arguments, the
derivation covers input store paths — and when they do, the fallback
above is what runs.

Evaluation writes to the store
------------------------------

Evaluation instantiates derivations: the `.drv` files `nix-eval-jobs`
reports are created as it goes, and Hydra cannot build them later unless
they are in the real store. A build sandbox has a read-only store view,
so a way to add paths back out is needed before any question of builds
*during* evaluation arises.

Recursive Nix's store-write half is exactly that, and it is already in
the pinned Nix (2.35-maintenance): `RestrictedStore::addToStore` and
`addToStoreFromDump` forward to the underlying store and call
`goal.addDependency()` on the new path. No permission check, no
experimental gate beyond `recursive-nix` itself, and no involvement of
content-addressed derivations — the only CA-flavoured members of that
class exist because `Store`'s interface demands them.

Crucially this is separable from builds during evaluation, and the
roadmap's ordering is wrong about it. Nested builds are a different
surface on the same class — `buildPaths`, `buildPathsWithResults`,
`ensurePath` — and they are where the *special* handling lives: stock
recursive Nix satisfies a nested build request locally, on the builder,
which is precisely what Hydra does not want. Routing those requests back
out to the queue runner, so the dependency becomes a scheduled step, is
the part that needs work.

Evaluation as a build needs none of that. It needs `addToStore` and
`addToStoreFromDump`, which stock recursive Nix already provides, with
`buildPaths` left refusing. So this does not depend on "recursive Nix
reaches the queue runner" at all — that is a prerequisite for builds
during evaluation, not for evaluation in a build.

A named pipe bound through `extra-sandbox-paths` is writable from
inside a build on stock Nix -- verified rather than assumed, since the
sandbox mounts the store read-only and the question was whether that
extends to a bound FIFO. It does not: Linux exempts FIFOs from the
read-only-mount check in `may_open`. `extra-sandbox-paths` is also
overridable by a trusted user, which `system-features` is not, so the
builder can bind the stream without a daemon config change.

Verified on stock Nix 2.35, rather than taken on faith: a sandboxed
derivation with `requiredSystemFeatures = [ "recursive-nix" ]` running
`nix store add-path` does add the path, and it is valid in the outer
store once the build finishes. That holds against a *relocated* store
(`local?root=…`), which is what Hydra runs on in the test harness, so
the earlier worry that a relocated store forces a chroot that
recursive Nix cannot live with is unfounded. `sandbox-build-dir must
not contain the storeDir` only bites when the store is genuinely
underneath the build directory.

Two conditions, and both are the same condition Hydra already has to
satisfy for its own tooling: the store's *logical* directory has to be
the one the paths are named with (a store opened with `&store=` pointing
somewhere else makes every `/nix/store/…` path foreign), and whatever
the build runs -- Nix itself included -- has to be in that store rather
than merely on the host.

The second is why this is not exercised by the Perl test suite: the
harness deliberately gives its store a logical directory under the
test's temporary directory so the builder and the evaluator agree on
one, and no `/nix/store` path is addressable there. The evaluation build
runs unsandboxed with an explicit `evaluation_build_store_uri` instead.
That is a property of the harness, not of the design, but it does mean
the production path is not covered by a test.

`nix-eval-jobs` is used unmodified, talking to the recursive-Nix daemon
socket like any other client. The build script does the plumbing:

    nix-eval-jobs ... | tee "$out" > /hydra/side-channel

which gets the authoritative output and the live stream out of one
unmodified process, with nothing that has to track the JSON format.

Retention was expected to fall out of the ordinary reference graph
rather than needing `--gc-roots-dir`: the JSONL contains
`/nix/store/…-foo.drv` strings, so reference scanning records those
derivations as references of `$out`, and rooting the evaluation build's
output would root every derivation it names.

That does not hold in practice — aggregate derivations were collectable
immediately after evaluation — so the roots are made explicitly instead,
by the run that reads the result. `--gc-roots-dir` is not available to
the evaluation any more, since the directory is outside the sandbox and
a build cannot write to it, but the same roots can be made on the way
back in, from the derivations the JSONL names.

Every job needs one, not only the jobs that become builds: an aggregate
is reported as a job and nothing else in the store refers to its
derivation. Worth revisiting whether the reference-graph argument can be
made to work, since it would make retention automatic rather than a step
that can be forgotten.

Gathering the inputs
--------------------

The hard part is separating input collection from evaluation, so the
inputs can go *into* the evaluation derivation rather than being fetched
by it. Hydra already has the information: `JobsetEvalInputs` records,
per evaluation and per input, its `type`, `uri`, `revision`, `value`,
`dependency` and — the one that matters — `path`, the materialized store
path. The fetchers already run ahead of evaluation and already persist
their results. What changes is where those paths are handed to: an
instantiation instead of a command line.

A consequence worth stating plainly: `--restrict-eval` stops being
load-bearing. Today it is the security boundary, because evaluation runs
unsandboxed on the Hydra host and must be prevented from reading outside
its declared inputs. When evaluation is a build, the sandbox enforces
that structurally — the evaluation can only see what is in the
derivation. Restricted eval becomes defence in depth at most.

Where evaluation builds live
----------------------------

In their own jobset, not in the jobset being evaluated. `Builds` needs a
non-null `jobset_id` and the honest answer is "none of them"; the
`drv-daemon` branch already establishes this pattern with its hidden
`adhoc/adhoc` jobset. Keeping them out of the evaluated jobset also
keeps them out of its build listings and success statistics, where they
would appear as a job nothing in the jobset names.

That jobset must be `enabled = 0`. The scheduler selects jobsets with

    WHERE j.enabled != 0 AND p.enabled != 0

so an enabled evaluation jobset would be scheduled for evaluation
itself — and evaluating it would want to create an evaluation build in
itself. Excluding it by construction beats a special case someone can
flip in the UI.

Retention deserves a deliberate answer rather than the default: this one
jobset accumulates a build per evaluation across the whole instance, so
it grows with jobsets times poll frequency.

The schema change
-----------------

One nullable column:

    ALTER TABLE JobsetEvals ADD COLUMN eval_build integer;
    ALTER TABLE JobsetEvals ADD CONSTRAINT jobsetevals_eval_build_fkey
      FOREIGN KEY (eval_build) REFERENCES Builds(id) ON DELETE SET NULL;

Cheap on purpose: a nullable `ADD COLUMN` is metadata-only, and the
constraint validates against an all-null column. Nothing is rewritten,
and `JobsetEvalMembers` — a row per build per evaluation, the table you
least want to migrate — is untouched.

A second one, for the same reason and at the same cost:

    ALTER TABLE JobsetEvals ADD COLUMN completed bigint;

`evalTime` and `hasNewBuilds` are `not null` but unknown until the
evaluation finishes, so a tentative row carries placeholders. Every
listing filtered on `hasNewBuilds`, which read the placeholder `0` as
"finished, found nothing" and hid the evaluation for exactly as long as
it was interesting; `completed` is what distinguishes a placeholder from
an answer.

It is also what tells the evaluator which evaluations still need reading
back. That cannot be inferred: an evaluation build finishing and its
results being consumed are separate events, and no other column
distinguishes them -- an evaluation may legitimately find no jobs and
legitimately take no measurable time.

`ON DELETE SET NULL`, never cascade. Evaluation builds live in a
high-churn jobset that will be garbage collected aggressively; a
cascading delete would remove the `JobsetEval` an aged-out build
produced, losing evaluations because their evaluator expired. Losing the
provenance while keeping the evaluation is the right failure mode.
`JobsetEvals.evaluationerror_id` already uses `on delete set null` for
the same reason.

The reference is to the build, not to a build step. With builds during
evaluation the evaluation build has several steps and there is no stable
"the" step to name; the build is the unit that *is* the evaluation, and
its root step is reachable from it (`state::Build.toplevel`) without
being recorded.

Because evaluation builds are not members of the evaluation they
produce, `JobsetEvalMembers` continues to mean exactly "the jobs of this
evaluation", and the standing TODO there —

    -- TODO use multicolumn primary key to make sure the eval and build
    -- agree on jobset.

— remains implementable.

Interaction with builds during evaluation
-----------------------------------------

Once step 3 of the roadmap lands, a build requested *during* an
evaluation becomes a step of the evaluation build, not a separate build.
Hydra normally derives a build's steps from the derivation's input
closure, known at queue time, and a dependency discovered mid-evaluation
is by definition not in it — but `create_build_step` allocates `stepnr`
dynamically, so appending a step to an in-flight build is already
mechanically supported.

If that holds, `JobsetEvalMembers.forEvaluation` (the `ifd-awareness`
branch) may become unnecessary: it exists to mark a member as "a build
the evaluation needed rather than a job", and steps are not members.
Worth settling before that branch lands, since it is a migration on the
largest table.

Nix changes we are deliberately not making
------------------------------------------

Everything above works on stock Nix 2.35; `recursive-nix` needs enabling
in the daemon's `experimental-features` and `system-features`, but that
is configuration, not a patch. Two Nix changes would make this nicer,
and are worth revisiting once it works:

- A first-class extra output stream from a build, so nothing has to be
  bind-mounted into the sandbox to get bytes out. Today the builder can
  only receive what the daemon reports as log messages, which is why the
  FIFO exists at all.
- Routing `RestrictedStore::buildPaths` back to the queue runner instead
  of satisfying it locally on the builder. That is what builds during
  evaluation will need, and it is the only part of recursive Nix that
  actually requires work — the store-write half is already enough for
  evaluation itself.

Open questions
--------------

- What assumes a build's step set is complete when it is queued?
  Progress display, the dispatcher's notion of what is runnable, and
  anything computing "steps remaining" are the likely candidates.
- Scheduling and priority: the evaluation build holds a slot while its
  nested builds run. This must not deadlock. (Carried over from the
  roadmap's open questions; still unanswered.)
- What this does *not* obsolete, and why. Very little of the evaluator's
  existing machinery died with this change: it still fetches inputs, locks
  jobsets while it does, limits how many run at once, and guards the
  coordinator's free disk. All of that survives for one reason -- input
  fetching still writes to the coordinator's store, and the queue runner
  still reads `.drv` files from it.

  So evaluation-as-a-build currently adds a layer rather than replacing
  those responsibilities. They go when the coordinator stops having a
  store at all: inputs fetched by the builder, results uploaded to the
  cache, `.drv` files fetched back from it to be run. That is the change
  this one is a prerequisite for, and the honest measure of whether the
  approach is right.

- Turning the streamed preview into rows. A running evaluation now
  lists the jobs it has found, read straight from the stream file, but
  they are names on a page rather than `JobsetEvalMembers`: making them
  rows means creating builds from an evaluation that has not finished,
  which starts building jobs before the evaluation they came from is
  known to have succeeded. That is a scheduling change, not a display
  one, and wants deciding on its own terms.

- Pushing the preview rather than polling it. The page shows the stream
  as of the request; `hydra-ws` (PR 1773) already tails log files and is
  the natural carrier for tailing this one too.
- Evaluation that fetches has no network in a sandbox. Pre-fetching
  every input is the principled answer and overlaps with materializing
  inputs as store paths above.
- Retention of the evaluations jobset. Still the default, which for a
  jobset that gains a build per evaluation across the whole instance is
  not an answer.
- How much of `nix-eval-jobs` survives when evaluation is a build?
  (Carried over from the roadmap.)

How it landed on the Rust evaluator
-----------------------------------

The Perl version of this branch split `hydra-eval-jobset` into a half that
schedules the evaluation build and a half that reads its result back.
`more-rust-eval` deleted that program, so the branch was rebased as a
rewrite: one commit, `hydra: Evaluate jobsets in builds`, resolves the
conflict by doing in Rust what the Perl did, and the commits after it
delete what the rewrite made redundant and replace the `hydra-evaluator`
crate with two: `hydra-submit-evaluation` and `hydra-process-evaluation`.
They share no code.
What one writes and the other reads is rows.

### What was deleted

- `max_concurrent_evals`, the kill and reap supervision, `running_evals`.
  Build scheduling is by builder capacity and system features.
- The scheduler's in-memory copy of every jobset, re-read on each
  notification, and the arithmetic over it deciding how long to sleep.
  One query asks the database which jobsets are due, including the
  one-at-a-time rule, and the loop wakes on a jobset event, a finished
  submission, or a short timer.
- `jobsets.startTime` as a lock, `unlock_all_jobsets`, `--unlock`, the
  `ExecStopPost` that called it, and finally the column itself.
- `JobsetEvals.evalTime`, the duration shown on the jobset page, and the
  column.
- The `FINISHER_INTERVAL` poll.
  `hydra-process-evaluation` listens for `build_finished` and catches up at startup.
- The `--jobs` dry run and its test.
  It was a Perl-era debugging aid, and the Rust evaluator never had one.
- The library crate the two binaries briefly shared, and the shared
  `queries.rs` with it.
  Splitting the queries by which half runs them showed the halves had two
  in common, and both of those turned out to be wrong for one side or the
  other.

### What the rewrite fixed on the way

- A trigger was cleared only when `startTime` was set, and nothing set it,
  so a manually triggered jobset stayed triggered in the database.
- `lastCheckedTime` was written only on failure; the in-memory copy hid it.
- `forceEval` was never reset, by the Perl either, so one forced push made
  every later evaluation skip the cache.
- Completing an evaluation inserted a second `EvaluationErrors` row and
  wrote the error there, while the evaluation still pointed at the empty
  one written when it was scheduled.
- The test harness put `evaluation_build_system_features` and
  `evaluation_build_store_uri` in `hydra.conf`, which the Rust never reads.
  It writes an `evaluator.toml` now, named by `HYDRA_EVALUATOR_CONFIG`.
- The derivation builder handed `builtins.storePath` the bare names Hydra
  keeps, and took the first `nix-eval-jobs` argument for the program.
  Neither could have worked; the tests had not been run since the rewrite.
- The hidden `hydra:evaluations` jobset was inserted without
  `emailoverride`, which is `not null`.
- `nix-eval-jobs` reports a job's `name` at the top level, not in `meta`,
  so every build got a null `nixname`. Inherited from the base.
- Eval inputs are stored as full paths, which is what the schema's store
  path columns hold and what the eval page parses. The base never wrote
  these rows at all, so nothing had noticed.
- A failed evaluation build now announces `eval_failed`, with the changed
  flag, the way a failed evaluation used to; the eval-error mail depends on
  it.

### Tests the base failed, fixed at the base

In this environment `more-rust-eval` failed eleven test files, nearly all
in the evaluation path. The fixes were made there first, folded into its
`hydra: Evaluate jobsets in Rust` commit, and this branch rebased on top;
where this branch had already rewritten the file, its version carries the
same fix. They were:

- Content-addressed jobs come back from `nix-eval-jobs` with `"out": null`,
  which the job struct rejected, dropping every such job.
- A declarative project's `.jobsets` jobset has no inputs of its own; the
  Perl evaluator fetched the project's declarative input, read the
  specification, and either created the jobsets from it or reconfigured
  `.jobsets` to generate them, and the rewrite had dropped that.
  `hydra-prepare-declarative-jobset` does it again, in Perl, since the
  helpers that write jobsets from a specification are shared with the web
  interface.
- Evaluated derivations were not rooted, so an aggregate's could be
  collected. Every job's derivation is rooted in the directory the queue
  runner uses.
- Eval inputs were stored as bare names where the schema holds full paths.
- The svn plugin reports `revNumber` as a string.
- A `build` input whose job has never been built was reported as "multiple
  alternatives"; it contributes nothing, as in the Perl.
- Whether a `build` input's output is present was asked of the daemon,
  which in tests only runs while a build does. `nix-store` is asked instead,
  and the harness sets `eval_substituter` to the destination store.
- `eval_started` and `builds_added` were no longer sent. The second is what
  wakes the queue runner; without it new builds waited for its poll.
- A successful evaluation neither cleared the jobset's previous error nor
  recorded when it was checked.
- A job's `name` was read from `meta`, where `nix-eval-jobs` does not put it.

### What was not, and why

- The `eval_added`/`eval_failed`/`eval_cached` channels and the
  eval-error mail plugin on top of them.
  Folding these into `build_finished` looks right but races:
  the queue runner sends `build_finished` for the evaluation build before
  `hydra-process-evaluation` has ingested its output,
  so a plugin woken by it would read the jobset before its error is written.
  Collapsing the three channels into one `eval_finished`, sent by
  `hydra-process-evaluation` after it commits, would delete the
  `error_changed` flag and two of the three `Hydra::Event::Eval*` classes
  without that race.
  Not done here, since it removes a feature merged in #1886 for a saving of
  a few hundred lines.

### A gap that predates this branch

`nix-eval-jobs --gc-roots-dir` used to root every job's derivation as it
was reported, and the Perl finisher re-created those roots on the way back.
The Rust evaluator on `more-rust-eval` passes no `--gc-roots-dir` and roots
nothing itself; the queue runner roots the derivations of builds it picks up.
So a job that is reported but never becomes a build -- an aggregate -- has
no root, and its derivation can be collected before anything refers to it.
This branch neither introduces nor fixes that.
