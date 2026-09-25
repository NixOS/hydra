use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

# Regression test for https://github.com/NixOS/hydra/issues/1907. Loading a
# build with a deep dependency chain overflowed the stack of a tokio worker
# thread in the queue runner, which then crash-looped.
#
# Debug logs grow quadratically with the chain depth and would fill the log pipe.
local $ENV{HYDRA_TEST_QUEUE_RUNNER_LOG} = "info";
my $builds = $ctx->makeAndEvaluateJobset(
    expression => "deep-chain.nix",
    build => 1
);

my $build = $builds->{"deep_chain"};
is($build->finished, 1, "Build should be finished.");
is($build->buildstatus, 2, "Build should fail because of the failing leaf dependency.");

done_testing;
