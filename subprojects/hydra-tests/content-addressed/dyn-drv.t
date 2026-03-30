use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

# FIXME now that we're properly resolving things in Hydra rather than Nix,
# dynamic derivations stopped-fake working
plan skip_all => 'dynamic derivation resolution not yet implemented';

# Based on https://github.com/NixOS/nix/blob/14ffc1787182b8702910788aea02bd5804afb32e/tests/functional/dyn-drv/text-hashed-output.nix
#
# A single derivation produces a .drv file as its output; another
# derivation (wrapper) depends on building that dynamically-produced .drv
# and using its output via builtins.outputOf.

my $ctx = test_context(
    nix_config => qq|
    experimental-features = ca-derivations dynamic-derivations
    |,
);

my $db = $ctx->db();

my $jobset = createBaseJobset($db, "dyn-drv", "dyn-drv.nix", $ctx->jobsdir);

ok(evalSucceeds($ctx, $jobset), "Evaluation of dyn-drv.nix should succeed");
is(nrQueuedBuildsForJobset($jobset), 1, "Should queue 1 build (wrapper)");

my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx, @builds), "All dynamic derivation builds should complete");

# hello and producingDrv are standard CA derivations, so they must succeed.
for my $build (grep { $_->job ne 'wrapper' } @builds) {
    $build->discard_changes;
    is($build->finished, 1, "Build '" . $build->job . "' should be finished");
    is($build->buildstatus, 0, "Build '" . $build->job . "' should succeed");
}

# wrapper is the dynamic derivation consumer.
# It exercises the full resolution path: build producingDrv, discover the .drv
# at its output, resolve via try_resolve + flatten_chain, build the resolved drv.
my ($wrapper) = grep { $_->job eq 'wrapper' } @builds;
ok(defined $wrapper, "wrapper (dynamic derivation consumer) build should exist");
if ($wrapper) {
    $wrapper->discard_changes;
    is($wrapper->finished, 1, "wrapper should be finished");
    is($wrapper->buildstatus, 0, "wrapper should succeed");

    # Hydra currently doesn't understand the dynamic derivation structure,
    # so it only sees 2 build steps (producingDrv + wrapper itself) rather
    # than the full chain (producingDrv + dynamic hello + wrapper).
    my $nrSteps = $wrapper->buildsteps->count;
    is($nrSteps, 2, "wrapper should have 2 build steps (dynamic structure not yet tracked)");
}

done_testing;
