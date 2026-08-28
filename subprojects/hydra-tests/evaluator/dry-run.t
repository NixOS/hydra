use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

# A dry run reports the jobs of an evaluation and records nothing.
#
# It cannot discover those jobs for itself: nothing evaluates in the
# evaluator any more, so running one would mean scheduling and building an
# evaluation -- exactly what a dry run must not do. The jobs are supplied
# instead, as a file of `nix-eval-jobs` output. Here that file is a previous
# evaluation build's `$out`; out of band it could be anything that produced
# the same JSONL.
#
# It lives in `hydra-finish-eval` because that is the half that reads jobs.
my $ctx = test_context();

my $jobsetCtx = $ctx->makeJobset(expression => "basic.nix");
my $jobset = $jobsetCtx->{"jobset"};

ok(evalSucceeds($ctx, $jobset), "evaluating the jobset should succeed");

my ($eval) = $jobset->jobsetevals;
my ($output) = $eval->eval_build->buildoutputs;
my $jobsFile = $ctx->{central}{nix_store_dir} . "/" . $output->path->to_string;
ok(-f $jobsFile, "the evaluation build's output is a file of jobs");

# A second jobset, so the dry run has something with no evaluation of its own.
my $otherCtx = $ctx->makeJobset(expression => "basic.nix");
my $other = $otherCtx->{"jobset"};

subtest "a dry run reports the jobs" => sub {
    local $ENV{HYDRA_DRY_RUN} = "1";
    my ($res, $stdout, $stderr) = $ctx->capture_cmd(60,
        "hydra-finish-eval", "--jobs", $jobsFile);

    is($res, 0, "the dry run should succeed") or diag($stderr);
    like($stderr, qr/^good job \S+: \S+$/m, "it should report the jobs it was given");
};

subtest "and records nothing" => sub {
    is(scalar($other->jobsetevals), 0, "no evaluation should have been created");
    is(scalar($other->builds), 0, "no builds should have been queued");

    # In particular it must not schedule an evaluation build, which is the
    # one thing a dry run could most easily do by accident.
    my $evalJobset = $ctx->db()->resultset('Jobsets')->find(
        { name => "evaluations", project => "hydra" });
    is(scalar($evalJobset->builds), 1,
        "only the first jobset's evaluation build should exist");
};

subtest "a dry run needs to be given the jobs" => sub {
    local $ENV{HYDRA_DRY_RUN} = "1";
    my ($res, $stdout, $stderr) = $ctx->capture_cmd(60, "hydra-finish-eval", "1");

    isnt($res, 0, "it should refuse rather than evaluate");
    like($stderr, qr/--jobs/, "and say what it needs");
};

done_testing;
