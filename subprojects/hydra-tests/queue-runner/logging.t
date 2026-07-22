use strict;
use warnings;
use Setup;
use Test2::V0;
use File::Slurper qw(read_text);
require Hydra::Helper::Nix;

my $ctx = test_context();
setup_catalyst_test($ctx);

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "logging.nix",
    build => 1
);

subtest "success" => sub {
    my $build = $builds->{"success"};
    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 0, "Build should have succeeded.");

    # getDrvLogPath wants HYDRA_DATA
    local $ENV{HYDRA_DATA} = $ctx->{central}{hydra_data} . "/data";
    my $logPath = Hydra::Helper::Nix::getDrvLogPath($build->drvpath) or die "Log file did not exist";
    my $logContent = read_text($logPath) or die "Could not read log file";
    ok(index($logContent, "should appear in success") != -1, "Log should contain correct content");
};

subtest "failure" => sub {
    my $build = $builds->{"failure"};
    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 1, "Build should have failed.");

    # getDrvLogPath wants HYDRA_DATA
    local $ENV{HYDRA_DATA} = $ctx->{central}{hydra_data} . "/data";
    my $logPath = Hydra::Helper::Nix::getDrvLogPath($build->drvpath) or die "Log file did not exist";
    my $logContent = read_text($logPath) or die "Could not read log file";
    ok(index($logContent, "should appear in failure") != -1, "Log should contain correct content");
};

done_testing;
