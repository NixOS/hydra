use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

# Evaluating a jobset does not run nix-eval-jobs in the evaluator. It
# instantiates a derivation that will, and queues it as an ordinary build, so
# that evaluation is scheduled and distributed like any other work.
#
# That makes evaluation two steps rather than one, and this test drives them
# apart -- calling `hydra-eval-jobset` directly for the first, rather than
# `evalSucceeds`, which does both -- so that the intermediate state is
# something we assert about rather than something that merely happens to work.
my $ctx = test_context();

my $jobsetCtx = $ctx->makeJobset(expression => "basic.nix");
my $jobset = $jobsetCtx->{"jobset"};

my ($res, $stdout, $stderr) = $ctx->capture_cmd(
    60, "hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name);
is($res, 0, "scheduling the evaluation should succeed") or diag($stderr);

my $eval;

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

    # The queue runner fills this in rather than inserting it, so it has to
    # exist from the start or the build's output is lost.
    ok(defined $build->buildoutputs->find({ name => "out" }),
        "the evaluation build should have an output row to fill in");
};

subtest "a tentative evaluation points at the build that will perform it" => sub {
    my @evals = $jobset->jobsetevals;
    is(scalar @evals, 1, "a tentative evaluation should exist while it runs");

    $eval = $evals[0];
    ok(defined $eval->eval_build, "the evaluation should name its build");
    is($eval->completed, undef, "and should not be marked completed yet");

    # The jobs are not known until the evaluation build has run, so nothing
    # should have been created for them.
    is(scalar($jobset->builds), 0, "no jobs should be queued yet");
};

subtest "completing the build completes the evaluation" => sub {
    ok(completeScheduledEvaluations($ctx, $jobset), "the evaluation should complete");

    $eval->discard_changes;
    ok(defined $eval->completed, "the evaluation should be marked completed");
    is($eval->eval_build->finished, 1, "its build should have finished");
    is($eval->eval_build->buildstatus, 0, "and succeeded");

    # Only now do the jobs exist, and they are ordinary builds of the jobset
    # being evaluated -- not of the jobset the evaluation build lives in.
    ok(scalar($jobset->builds) > 0, "the jobs should now be queued");
    is($eval->hasnewbuilds, 1, "and the evaluation should say so");
};

done_testing;
