use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

# Regression test: when a build is already finished in the DB (e.g. cached
# derivation from a parallel test job), `runBuild` should
# succeed rather than failing on the 404 from `/build_one`.

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

my $build = $builds->{"empty_dir"};
is($build->finished, 1, "Build should be finished after first run.");
is($build->buildstatus, 0, "Build should have succeeded.");

# Build the same (already-finished) build again.  The /build_one endpoint
# returns 404 for finished builds; the script must treat that as success.
ok(runBuild($build), "Re-building an already-finished build should succeed.");

done_testing;
