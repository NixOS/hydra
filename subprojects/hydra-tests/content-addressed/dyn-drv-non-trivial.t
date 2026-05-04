use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

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

    # Full dynamic derivation chain: 12 steps total
    # 1.  make-derivations.drv.drv  (status=0,  build makeDerivations)
    # 2.  build-a.drv               (status=0,  build a)
    # 3.  build-c.drv               (status=13, resolve c)
    # 4.  build-b.drv               (status=13, resolve b)
    # 5.  build-b.drv               (status=0,  build resolved b)
    # 6.  build-c.drv               (status=0,  build resolved c)
    # 7.  build-d.drv               (status=13, resolve d)
    # 8.  build-d.drv               (status=0,  build resolved d)
    # 9.  make-derivations.drv      (status=13, resolve e — named after makeDerivations output)
    # 10. make-derivations.drv      (status=0,  build resolved e)
    # 11. wrapper.drv               (status=13, resolve wrapper)
    # 12. wrapper.drv               (status=0,  build resolved wrapper)
    my @steps = $wrapper->buildsteps->search({}, { order_by => 'stepnr' })->all;
    is(scalar @steps, 12, "wrapper should have 12 build steps");

    # Check that derivations a-d each got a successful (status=0) build step.
    # build-e is named make-derivations.drv (the output of makeDerivations),
    # so we check for it separately.
    my @built = sort map {
        my $drv = $_->drvpath // "";
        (defined $_->status && $_->status == 0 && $drv =~ m{-build-([a-d])\.drv$}) ? $1 : ()
    } @steps;
    is(\@built, [qw(a b c d)], "derivations a-d should each have a successful build step");

    # build-e is the make-derivations.drv step (status=0, not the .drv.drv)
    my @build_e = grep {
        my $drv = $_->drvpath // "";
        defined $_->status && $_->status == 0 && $drv =~ m{-make-derivations\.drv$}
    } @steps;
    is(scalar @build_e, 1, "build-e (make-derivations.drv) should have a successful build step");
}

done_testing;
