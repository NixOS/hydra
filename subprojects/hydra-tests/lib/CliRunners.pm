use warnings;
use strict;

package CliRunners;
use Hydra::Helper::Exec;
use QueueRunnerBuildOne;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    completeScheduledEvaluations
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
sub completeScheduledEvaluations {
    my ($ctx, $jobset) = @_;

    my @pending = $jobset->jobsetevals->search(
        { eval_build => { '!=' => undef }, evaltime => 0 },
        { order_by => 'id' });

    for my $ev (@pending) {
        my $build = $ev->eval_build;
        runBuilds($ctx, $build) unless $build->finished;
        $build->discard_changes;

        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        my ($res, $stdout, $stderr) = captureStdoutStderr(60,
            ("hydra-eval-jobset", "--finish-evaluation", $ev->id));
        if ($res) {
            chomp $stdout; chomp $stderr;
            print STDERR "Finishing evaluation " . $ev->id . " failed.\n";
            print STDERR "STDOUT: $stdout\n" if $stdout ne "";
            print STDERR "STDERR: $stderr\n" if $stderr ne "";
            return 0;
        }
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
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
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
