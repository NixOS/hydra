Landing plan: evaluation as a build
===================================

Working notes on how this branch should be cut up before it goes
anywhere. Temporary, like `eval-in-build.md` — delete or fold into the
docs once the PRs are open.

The short version
-----------------

The branch is currently +2900/-190 across 49 files, and that ratio is
the problem rather than the size. A change that moves evaluation out of
the evaluator ought to *remove* evaluator responsibilities, and this one
mostly does not. Two reasons, and they suggest two different fixes.

One piece of speculative infrastructure got carried along, and the rest
is the honest cost of making evaluation asynchronous.

What a preparatory refactor would and would not have bought
----------------------------------------------------------

`hydra-eval-jobset` is spawned by `hydra-evaluator` as a one-shot
process, and evaluation-as-a-build makes it two of them: one to schedule
the evaluation, one to read the result back. The obvious conclusion is
that folding it into the evaluator first, as a non-functional change
under the old design, would have removed the plumbing between them.

That conclusion is mostly wrong, and it is worth writing down why.

The two halves are not separated by a process boundary. They are
separated by a *time* boundary: the evaluation build can take hours, and
can outlive any daemon restart. So the state connecting them has to be
durable and re-derivable from the database whoever owns it. A long-lived
worker cannot hold a jobset's evaluation context in memory across that
gap -- and would not want to.

So of the code that looks like marshalling:

- `finishScheduledEvaluation`'s 66 lines are recovery, not plumbing.
  Only the two lookups at the top re-derive anything; the rest is the
  actual work of consuming a finished build -- check it finished, replay
  its log, handle failure, find its output, build the iterator, compute
  how long it took. Any design needs all of it.
- `JobsetEvals.trace_id` has to be a column for the same reason: it must
  survive a restart.
- `eval_build` and `completed` likewise.

What a fold would actually have saved is the `--finish-evaluation`
argument parsing and one per-process config-and-database setup. That is
not nothing, but it is not a reason to reorder the work.

There may be other reasons to fold -- one language, one configuration
load, no process spawned per jobset, and the comment in
`nixos-modules/web-app.nix` anticipating it:

    # Because hydra-evaluator calls `hydra-eval-jobset`. If we
    # move that perl script into rust, then we can get rid of this.

-- but "it would have made this feature smaller" is not one of them.

Which half could move, if it ever does
--------------------------------------

The plugin boundary is clean, and it falls exactly on the
schedule/complete split. Plugins are input types, reached only through
`fetchInput`, which only the scheduling half calls. The completion half
needs none: both `finishEvaluation` and `checkBuild` were taking a
`$plugins` argument and never using it.

So the half that could move without disturbing the plugin system is
precisely the half this feature added. It is still the wrong one to
move: it is where the domain subtlety lives -- `checkBuild`, aggregates
and constituents with their globbing, transitivity and cycle detection,
and the per-attribute error assembly behind `EvaluationErrors`. That is
the code with the most tests and the most ways to be quietly wrong.

What should not be in this at all
---------------------------------

The named output streams — `hydraStreams`, the builder's relay, the
proto messages, the queue runner persisting them — are 297 lines of new
Rust and protocol for a data path that no test ever exercises. The
stream reaches the build through `extra-sandbox-paths`, which binds
nothing in an unsandboxed build, and unsandboxed is what the harness
runs; so the `if [ -e "$evalStream" ]` in the evaluation's build script
takes the else branch every single time the suite runs.

That is not an argument that the mechanism is wrong. It is an argument
that it is a separate feature: it is optional by construction (the
design note is explicit that `$out` is authoritative and the stream is
a latency optimisation), it has its own protocol change, and it should
stand or fall on its own merits rather than ride along inside a core
scheduling change.

Proposed order
--------------

Each of these should be independently reviewable, and the early ones
independently landable today.

1. **Cleanup, no behaviour change.** `permute` and `getEvalInputs`, both
   already dead. Perlcritic on the store path classes. `gcRootFor`
   dropped from `@EXPORT`.

2. **Make the two halves of Hydra agree on where build logs live.** The
   queue runner was given `$HYDRA_DATA/data` while the Perl looks in
   `$HYDRA_DATA`; `logging.t` worked around it. Independently valuable,
   and a prerequisite for anything Perl-side reading a build's log.

3. **Builds of disabled jobsets out of the cross-jobset APIs.**
   `/api/latestbuilds` and `/api/nrbuilds`. Defensible on its own — it
   is what `clear_queue_non_current` already does.

4. **Schema.** Migration 89: `eval_build`, `completed` and `trace_id`,
   all nullable and metadata-only.

5. **Evaluation as a build.** The feature. Needs 4.

6. **UI.** In-flight evaluations made visible: `visibleEvalsCond`, the
   jobset page reading the evaluation's build rather than
   `Jobsets.startTime`, the evaluation page's banner. Needs 5.

7. **Dry run via `--jobs`.** Needs 5.

8. **Named output streams, and the jobs-found-so-far preview.** Its own
   feature, and the only one whose data path is currently untested.

History cleanup
---------------

The commits as they stand are a record of finding things out, not a
sequence anyone should review: the schema is amended three times,
`commit-89.txt` is rewritten twice, and several commits exist only to
fix the one before. Squash to the shape above.

Two things worth preserving rather than losing to a squash, because
they were established experimentally and are cheap to get wrong again:
recursive-nix store writes work on stock Nix against a relocated store,
and a FIFO bound through `extra-sandbox-paths` is writable from inside
a build. Both are written up in `eval-in-build.md`; the notes should
outlive the branch even if these commits do not.
