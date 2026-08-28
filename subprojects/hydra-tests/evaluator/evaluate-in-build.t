use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

# Evaluating a jobset does not run nix-eval-jobs in the evaluator.
# It instantiates a derivation that will, and queues it as an ordinary build,
# so that evaluation is scheduled and distributed like any other work.
#
# The evaluation is finished when that build completes, which is a separate
# step: nothing here waits for it, because the queue runner is what dispatches
# builds and blocking would hold an evaluator slot until it did.
my $ctx = test_context(
    hydra_config => q|
    # This store lives under the outer build's /build, so requiring
    # recursive-nix would force a sandbox that Nix then refuses:
    # `sandbox-build-dir must not contain the storeDir`. Builds here are
    # unsandboxed against a writable store, which gives the evaluation the
    # store access it needs by another route.
    evaluation_build_system_features =
    |
);

my $jobsetCtx = $ctx->makeJobset(expression => "basic.nix");
my $jobset = $jobsetCtx->{"jobset"};

ok(evalSucceeds($jobset), "evaluating the jobset should succeed");

subtest "an evaluation build is queued" => sub {
    my $evalJobset = $ctx->db()->resultset('Jobsets')->find(
        { name => "evaluations", project => "hydra" });
    ok(defined $evalJobset, "the evaluations jobset should exist");

    # It must never be scheduled for evaluation itself: the evaluator selects
    # jobsets with `enabled != 0`, and evaluating this one would want to
    # create an evaluation build inside itself.
    is($evalJobset->enabled, 0, "the evaluations jobset must be disabled");

    my @builds = $evalJobset->builds;
    is(scalar @builds, 1, "exactly one evaluation build should be queued");

    my $build = $builds[0];
    is($build->finished, 0, "the evaluation build should still be queued");
    like($build->drvpath, qr/hydra-eval-/, "it should build the evaluation derivation");
};

subtest "the evaluation points at the build that will perform it" => sub {
    my @evals = $jobset->jobsetevals;
    is(scalar @evals, 1, "a tentative evaluation should exist while it runs");

    my $eval = $evals[0];
    ok(defined $eval->eval_build, "the evaluation should name its build");

    my $build = $ctx->db()->resultset('Builds')->find($eval->eval_build->id);
    is($build->jobset_id, $eval->eval_build->jobset_id,
        "that build is the queued evaluation build");
};

subtest "the jobset itself gained no builds" => sub {
    # The jobs are not known until the evaluation build has run, so nothing
    # should have been created for them yet.
    is(scalar($jobset->builds), 0, "no jobs should be queued yet");
};

done_testing;
