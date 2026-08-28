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

The first is that a refactor got skipped. The second is that a piece of
speculative infrastructure got carried along.

What should have come first
---------------------------

`hydra-eval-jobset` is spawned by `hydra-evaluator` as a one-shot
process. Evaluation-as-a-build makes it *two* one-shot processes — one
to schedule, one to read the result back — and everything that has to
survive between them has to be marshalled through the database and the
command line:

- `finishScheduledEvaluation`, 66 lines, almost all of it re-deriving
  state from an eval id: the eval, its build, the build's output, the
  jobset, the project, the duration, the trace.
- `recordEvaluationFailure`, 30 lines, factored out only because there
  are two entry points that can fail.
- `--finish-evaluation`, its argument parsing and its usage string.
- `JobsetEvals.trace_id`, a column whose only job is to correlate two
  processes.
- On the Rust side, a daemon querying a table to discover work that the
  same daemon created.

Call it 150–200 lines plus a column, none of which is the feature.

Folding `hydra-eval-jobset` into `hydra-evaluator` first — as a
non-functional change, under the old design, where it is reviewable on
its own and cannot break anything — would have removed nearly all of
that before it was ever written. `nixos-modules/web-app.nix` already
carries the comment anticipating this:

    # Because hydra-evaluator calls `hydra-eval-jobset`. If we
    # move that perl script into rust, then we can get rid of this.

`eval_build` and `completed` stay either way: an evaluation build can
run for hours and outlive any process, so that state has to be durable
no matter who owns it. The fold removes the marshalling, not the schema.

Which half, though
------------------

The plugin boundary turns out to be clean, and it falls exactly on the
schedule/complete split. Plugins are input types, reached only through
`fetchInput`, which only the scheduling half calls. The completion half
needs none: both `finishEvaluation` and `checkBuild` were taking a
`$plugins` argument and never using it.

So "move the part that does not touch plugins" is a real option, and it
is precisely the half this feature added. It is still the wrong trade.
The completion half is plugin-free but it is where all the domain
subtlety lives -- `checkBuild`, aggregates and constituents with their
globbing and transitivity and cycle detection, and the per-attribute
error assembly behind `EvaluationErrors`. That is the code with the most
tests and the most ways to be quietly wrong, and porting it buys nothing
the cheaper option does not.

The cheaper option is to leave both halves in Perl and stop spawning two
one-shot processes: one persistent worker the evaluator drives. That
removes `--finish-evaluation`, the 66 lines of state re-derivation and
the `trace_id` column without moving a line of domain logic or going
near the plugin system.

Doing any of it afterwards is strictly harder, since the refactor now
has to preserve behaviour that did not exist when it was proposed.

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

4. **The fold.** `hydra-eval-jobset` becomes a persistent worker rather
   than a one-shot process; the input plugins stay in Perl and do not
   move. Non-functional. This is the one that was skipped, and
   everything after it gets smaller.

5. **Schema.** Migration 89: `eval_build`, `completed`, and `trace_id`
   only if 4 did not happen. All nullable, metadata-only.

6. **Evaluation as a build.** The feature. Needs 5.

7. **UI.** In-flight evaluations made visible: `visibleEvalsCond`, the
   jobset page reading the evaluation's build rather than
   `Jobsets.startTime`, the evaluation page's banner. Needs 6.

8. **Dry run via `--jobs`.** Needs 6.

9. **Named output streams, and the jobs-found-so-far preview.** Its own
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
