use warnings;
use strict;

package CliRunners;
use Hydra::Helper::Exec;
use QueueRunnerBuildOne;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    completeScheduledEvaluations
    captureEvaluation
    evalFails
    evalSucceeds
    runBuild
    runBuilds
    sendNotifications
);

# Evaluating a jobset schedules a build that performs the evaluation; the
# evaluation is finished when that build completes. Drive both steps here so
# that a test asking for an evaluation gets a finished one, as it did when
# the evaluator did the work itself.
#
# In production the second step is triggered by the build completing. Here
# the queue runner only runs when a test asks it to, so the sequence is
# explicit: schedule, build, finish.
# Build and complete every evaluation of $jobset that is waiting for it, and
# return the ($res, $stdout, $stderr) of that work as though it were one
# command: the first non-zero exit, with the output of every run concatenated.
#
# Tests that care about *how* an evaluation failed want this rather than
# `completeScheduledEvaluations`, because the failure is no longer reported by
# the run that schedules the evaluation. Evaluating is what fails -- a broken
# aggregate, a constituent that does not exist -- and evaluating now happens
# in the build, so the diagnosis comes out of the run that reads its result.
sub finishScheduledEvaluations {
    my ($ctx, $jobset) = @_;

    my @pending = $jobset->jobsetevals->search(
        { eval_build => { '!=' => undef }, completed => undef },
        { order_by => 'id' });

    my ($result, $out, $err) = (0, "", "");

    for my $ev (@pending) {
        my $build = $ev->eval_build;
        runBuilds($ctx, $build) unless $build->finished;
        $build->discard_changes;

        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        my ($res, $stdout, $stderr) = captureStdoutStderr(60,
            ("hydra-eval-jobset", "--finish-evaluation", $ev->id));
        $result = $res if $res && !$result;
        $out .= $stdout;
        $err .= $stderr;
    }

    return ($result, $out, $err);
}

# A whole evaluation -- schedule it, build it, complete it -- reported as the
# single command it used to be: ($res, $stdout, $stderr), with the two runs'
# output concatenated and the first non-zero exit.
#
# For tests that assert on how an evaluation went. Scheduling almost always
# succeeds, since it is only instantiating a derivation; what a test is
# usually looking for happens in the run that reads that derivation's result.
sub captureEvaluation {
    my ($ctx, $jobsetCtx) = @_;

    my $jobset = $jobsetCtx->{"jobset"};
    my ($res, $out, $err) = $ctx->capture_cmd(60,
        "hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name);
    return ($res, $out, $err) if $res;

    my ($finishRes, $finishOut, $finishErr) = finishScheduledEvaluations($ctx, $jobset);
    return ($finishRes, $out . $finishOut, $err . $finishErr);
}

# As above, but for tests that only need the evaluation to have happened.
sub completeScheduledEvaluations {
    my ($ctx, $jobset) = @_;

    my ($res, $stdout, $stderr) = finishScheduledEvaluations($ctx, $jobset);
    # Again: the error a test looks at is recorded by the run that evaluates,
    # which is this one, after whatever refresh the caller already did.
    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });
    if ($res) {
        chomp $stdout; chomp $stderr;
        print STDERR "Finishing the evaluation failed.\n";
        print STDERR "STDOUT: $stdout\n" if $stdout ne "";
        print STDERR "STDERR: $stderr\n" if $stderr ne "";
        return 0;
    }

    return 1;
}

sub evalSucceeds {
    my ($ctx, $jobset) = @_;
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    if ($res) {
        chomp $stdout; chomp $stderr;
        utf8::decode($stdout) or die "Invalid unicode in stdout.";
        utf8::decode($stderr) or die "Invalid unicode in stderr.";
        print STDERR "Evaluation unexpectedly failed for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
        print STDERR "STDOUT: $stdout\n" if $stdout ne "";
        print STDERR "STDERR: $stderr\n" if $stderr ne "";
    }
    return 0 if $res;
    return completeScheduledEvaluations($ctx, $jobset);
}

sub evalFails {
    my ($ctx, $jobset) = @_;
    # Both runs, because scheduling an evaluation almost always succeeds --
    # it only instantiates a derivation. What fails is evaluating, which
    # happens in the build.
    my ($res, $stdout, $stderr) = do {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    };
    if (!$res) {
        my ($finRes, $finOut, $finErr) = finishScheduledEvaluations($ctx, $jobset);
        ($res, $stdout, $stderr) = ($finRes, $stdout . $finOut, $stderr . $finErr);
        $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });
    }
    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    if (!$res) {
        chomp $stdout; chomp $stderr;
        utf8::decode($stdout) or die "Invalid unicode in stdout.";
        utf8::decode($stderr) or die "Invalid unicode in stderr.";
        print STDERR "Evaluation unexpectedly succeeded for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
        print STDERR "STDOUT: $stdout\n" if $stdout ne "";
        print STDERR "STDERR: $stderr\n" if $stderr ne "";
    }
    return !!$res;
}

sub sendNotifications {
    my ($ctx) = @_;
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-notify", "--queued-only"));
    if ($res) {
        utf8::decode($stdout) or die "Invalid unicode in stdout.";
        utf8::decode($stderr) or die "Invalid unicode in stderr.";
        print STDERR "hydra notify stdout: $stdout\n" if $stdout ne "";
        print STDERR "hydra notify stderr: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

1;
