use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

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

# wrapper is the only queued build — it is the dynamic derivation consumer.
# It exercises the full resolution path: build producingDrv, discover the .drv
# at its output, resolve via try_resolve + flatten_chain, build the resolved drv.
my ($wrapper) = @builds;
ok(defined $wrapper, "wrapper (dynamic derivation consumer) build should exist");
if ($wrapper) {
    $wrapper->discard_changes;
    is($wrapper->finished, 1, "wrapper should be finished");
    is($wrapper->buildstatus, 0, "wrapper should succeed");

    # Full dynamic derivation chain: 4 steps total
    # 1. hello.drv.drv        (status=0,  build producingDrv — outputs a .drv file)
    # 2. hello.drv             (status=0,  build the dynamically-produced derivation)
    # 3. dyn-drv-wrapper.drv   (status=13, resolve wrapper — CA resolution step)
    # 4. dyn-drv-wrapper.drv   (status=0,  build the resolved wrapper derivation)
    my @steps = $wrapper->buildsteps->search({}, { order_by => 'stepnr' })->all;
    is(scalar @steps, 4, "wrapper should have 4 build steps");

    # producingDrv: builds the .drv file (hello.drv.drv)
    my @producing_drv = grep {
        my $drv = $_->drvpath // "";
        defined $_->status && $_->status == 0 && $drv =~ m{-hello\.drv\.drv$}
    } @steps;
    is(scalar @producing_drv, 1, "producingDrv (hello.drv.drv) should have a successful build step");

    # The dynamically-produced derivation (hello.drv, not hello.drv.drv)
    my @dyn_drv = grep {
        my $drv = $_->drvpath // "";
        defined $_->status && $_->status == 0 && $drv =~ m{-hello\.drv$}
    } @steps;
    is(scalar @dyn_drv, 1, "dynamically-produced hello.drv should have a successful build step");

    # wrapper CA resolution step (status=13 means Resolved)
    my @resolved = grep {
        my $drv = $_->drvpath // "";
        defined $_->status && $_->status == 13 && $drv =~ m{-dyn-drv-wrapper\.drv$}
    } @steps;
    is(scalar @resolved, 1, "wrapper should have a resolution step (status=Resolved)");

    # wrapper final build (status=0)
    my @wrapper_built = grep {
        my $drv = $_->drvpath // "";
        defined $_->status && $_->status == 0 && $drv =~ m{-dyn-drv-wrapper\.drv$}
    } @steps;
    is(scalar @wrapper_built, 1, "resolved wrapper should have a successful build step");
}

done_testing;
