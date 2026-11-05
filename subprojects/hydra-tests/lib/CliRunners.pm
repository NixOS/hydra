use warnings;
use strict;

package CliRunners;
use File::Slurper qw(read_text);
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

# Evaluating a jobset schedules a build that performs the evaluation, and
# the evaluation is finished when that build has been read back. In
# production the second step is triggered by the build completing; here the
# queue runner only runs when a test asks it to, so the steps are driven
# explicitly: submit, build, process.
#
# Build and process every evaluation of $jobset that is waiting for it, and
# return the ($res, $stdout, $stderr) of that work as though it were one
# command: the first non-zero exit, with the output of every run concatenated.
# What `nix-eval-jobs` printed is in the build's log now rather than on
# anyone's stderr, so the log is replayed into $stderr: that is where a test
# looks for the diagnosis of a broken aggregate or a missing constituent.
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

        # Where the queue runner keeps logs: bucketed by the first two
        # characters of the derivation's name. Not `getDrvLogPath`, whose
        # module fixes the database connection at load time, before the
        # test context has said which database that is.
        my $drv = $build->drvpath->to_string;
        my $log = "$ctx->{central}{hydra_data}/build-logs/"
            . substr($drv, 0, 2) . "/" . substr($drv, 2);
        $err .= read_text($log) if -f $log;

        my ($res, $stdout, $stderr) =
            $ctx->capture_cmd(60, "hydra-process-evaluation", "--once");
        $result = $res if $res && !$result;
        $out .= $stdout;
        $err .= $stderr;
    }

    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });
    return ($result, $out, $err);
}

# A whole evaluation -- submit it, build it, process it -- reported as the
# single command it used to be.
sub captureEvaluation {
    my ($ctx, $jobset) = @_;
    $jobset = $jobset->{"jobset"} if ref $jobset eq "HASH";

    my ($res, $out, $err) = $ctx->capture_cmd(60,
        "hydra-submit-evaluation", $jobset->project->name, $jobset->name);
    return ($res, $out, $err) if $res;

    my ($finishRes, $finishOut, $finishErr) = finishScheduledEvaluations($ctx, $jobset);
    return ($finishRes, $out . $finishOut, $err . $finishErr);
}

# As above, but for tests that submitted the evaluation themselves and only
# need it to have been completed.
sub completeScheduledEvaluations {
    my ($ctx, $jobset) = @_;
    my ($res, $stdout, $stderr) = finishScheduledEvaluations($ctx, $jobset);
    diagnoseEvaluation("failed", $jobset, $stdout, $stderr) if $res;
    return !$res;
}

sub evalSucceeds {
    my ($ctx, $jobset) = @_;
    my ($res, $stdout, $stderr) = captureEvaluation($ctx, $jobset);
    diagnoseEvaluation("failed", $jobset, $stdout, $stderr) if $res;
    return !$res;
}

sub evalFails {
    my ($ctx, $jobset) = @_;
    my ($res, $stdout, $stderr) = captureEvaluation($ctx, $jobset);
    diagnoseEvaluation("succeeded", $jobset, $stdout, $stderr) if !$res;
    return !!$res;
}

sub diagnoseEvaluation {
    my ($what, $jobset, $stdout, $stderr) = @_;
    chomp $stdout; chomp $stderr;
    utf8::decode($stdout) or die "Invalid unicode in stdout.";
    utf8::decode($stderr) or die "Invalid unicode in stderr.";
    print STDERR "Evaluation unexpectedly $what for jobset "
        . $jobset->project->name . ":" . $jobset->name . ": \n" . $jobset->errormsg . "\n"
        if $jobset->errormsg;
    print STDERR "STDOUT: $stdout\n" if $stdout ne "";
    print STDERR "STDERR: $stderr\n" if $stderr ne "";
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
