use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

# FIXME now that we're properly resolving things in Hydra rather than Nix,
# dynamic derivations stopped-fake working
plan skip_all => 'dynamic derivation resolution not yet implemented';

# Adapted from https://github.com/NixOS/nix/blob/master/tests/functional/dyn-drv/non-trivial.nix
#
# A single derivation uses recursive-nix to dynamically create a DAG of
# inner derivations (a through e) via `nix derivation add`, then outputs
# the final .drv path.  A wrapper depends on building that
# dynamically-produced .drv and using its output via builtins.outputOf.

my $ctx = test_context(
    nix_config => qq|
    experimental-features = ca-derivations dynamic-derivations recursive-nix
    extra-system-features = recursive-nix
    |,
);

my $db = $ctx->db();

my $jobset = createBaseJobset($db, "dyn-drv-non-trivial", "dyn-drv-non-trivial.nix", $ctx->jobsdir);

ok(evalSucceeds($ctx, $jobset), "Evaluation of dyn-drv-non-trivial.nix should succeed");
is(nrQueuedBuildsForJobset($jobset), 1, "Should queue 1 build (wrapper)");

my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx, @builds), "All builds should complete");

# wrapper is the dynamic derivation consumer.
# It exercises the full chain: build makeDerivations (which uses
# recursive-nix to create derivations a-e), discover the .drv at its
# output, build that .drv (transitively building a through e), and use
# its output.
my ($wrapper) = grep { $_->job eq 'wrapper' } @builds;
ok(defined $wrapper, "wrapper build should exist");
if ($wrapper) {
    $wrapper->discard_changes;
    is($wrapper->finished, 1, "wrapper should be finished");
    is($wrapper->buildstatus, 0, "wrapper should succeed");
}

done_testing;
