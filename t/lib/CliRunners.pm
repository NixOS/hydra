use warnings;
use strict;

package CliRunners;
use Hydra::Helper::Exec;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    evalFails
    evalSucceeds
    runBuild
    sendNotifications
);

sub evalSucceeds {
    my ($jobset) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    $jobset->discard_changes;  # refresh from DB
    if ($res) {
        chomp $stdout; chomp $stderr;
        utf8::decode($stdout) or die "Invalid unicode in stdout.";
        utf8::decode($stderr) or die "Invalid unicode in stderr.";
        print STDERR "Evaluation unexpectedly failed for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
        print STDERR "STDOUT: $stdout\n" if $stdout ne "";
        print STDERR "STDERR: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

sub evalFails {
    my ($jobset) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    $jobset->discard_changes;  # refresh from DB
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

sub runBuild {
    my ($build) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-queue-runner", "-vvvv", "--build-one", $build->id));
    if ($res) {
        utf8::decode($stdout) or die "Invalid unicode in stdout.";
        utf8::decode($stderr) or die "Invalid unicode in stderr.";
        print STDERR "Queue runner stdout: $stdout\n" if $stdout ne "";
        print STDERR "Queue runner stderr: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

sub sendNotifications() {
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
