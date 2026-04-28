use warnings;
use strict;

package CliRunners;
use Hydra::Helper::Exec;
use QueueRunnerBuildOne;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    evalFails
    evalSucceeds
    runBuild
    runBuilds
    sendNotifications
);

# When $ctx has a DrvDaemonContext attached (HYDRA_TEST_USE_DRV_DAEMON
# env), eval children get NIX_REMOTE pointed at the daemon socket so
# IFD store ops route through it.
sub _eval_env {
    my ($ctx) = @_;
    my %env = %{ $ctx->{central_env} };
    my $d = $ctx->drv_daemon;
    $env{NIX_REMOTE} = $d->nix_remote_url if $d;
    return %env;
}

sub evalSucceeds {
    my ($ctx, $jobset) = @_;
    my %env = _eval_env($ctx);
    local @ENV{keys %env} = values %env;
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
    return !$res;
}

sub evalFails {
    my ($ctx, $jobset) = @_;
    my %env = _eval_env($ctx);
    local @ENV{keys %env} = values %env;
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
