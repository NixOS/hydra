use strict;
use warnings;
use Setup;
use Test2::V0;

# Regression test for the harmonia-store-core bug fixed in 2f09d76:
# a missing trailing colon in the FOD fingerprint
# "fixed:out:<hashAlgo>:<hex>:" caused output_paths() to compute wrong
# store paths for fixed-output derivations.
#
# The queue runner now checks that, for outputs with statically-known
# paths (input-addressed and fixed CA), the paths reported by the
# builder match what output_paths() computes.  A mismatch is a hard
# error, so a broken output_paths() will cause the first build to fail.
#
# Additionally, building the same FOD a second time exercises caching:
# the queue runner should detect the output already in its store and
# mark the build as isCachedBuild.

my $ctx = test_context(
    use_external_destination_store => 0,
);

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "fod.nix",
    build => 1,
);

subtest "FOD build succeeds (output_paths agrees with builder)" => sub {
    my $build = $builds->{"fod"};
    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 0, "Build should have succeeded.");

    my $out = $build->buildoutputs->find({ name => "out" });
    ok(defined $out, "Build should have an 'out' output");
};

# Build the same FOD again.  The output is already in the queue
# runner's store, so this time it should be recognised as cached.
my $builds2 = $ctx->makeAndEvaluateJobset(
    expression => "fod.nix",
    build => 1,
);

subtest "Second build is recognised as cached" => sub {
    my $build = $builds2->{"fod"};
    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 0, "Build should have succeeded.");
    is($build->iscachedbuild, 1,
        "Build should be cached (output_paths must compute the correct store path)");
};

done_testing;
