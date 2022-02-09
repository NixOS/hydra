use strict;
use warnings;
use Setup;
use Data::Dumper;
use Test2::V0;
use Hydra::Helper::Exec;

my $ctx = test_context(
    use_external_destination_store => 1
);

require Hydra::Helper::Nix;

# This test is regarding https://github.com/NixOS/hydra/pull/1126
#
# A hydra instance was regularly failing to build derivations with:
#
#     possibly transient failure building ‘/nix/store/X.drv’ on ‘localhost’:
#     dependency '/nix/store/Y' of '/nix/store/Y.drv' does not exist,
#     and substitution is disabled
#
# However it would only fail when building on localhost, and it would only
# fail if the build output was already in the binary cache.
#
# This test replicates this scenario by having two jobs, underlyingJob and
# dependentJob. dependentJob depends on underlyingJob. We first build
# underlyingJob and copy it to an external cache. Then forcefully delete
# the output of underlyingJob, and build dependentJob. In order to pass
# it must either rebuild underlyingJob or fetch it from the cache.


subtest "Building, caching, and then garbage collecting the underlying job" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "dependencies/underlyingOnly.nix",
        build => 1
    );

    my $path = $builds->{"underlyingJob"}->buildoutputs->find({ name => "out" })->path;

    ok(unlink(Hydra::Helper::Nix::gcRootFor($path)), "Unlinking the GC root for underlying Dependency succeeds");

    (my $ret, my $stdout, my $stderr) = captureStdoutStderr(1, "nix-store", "--delete", $path);
    is($ret, 0, "Deleting the underlying dependency should succeed");
};

subtest "Building the dependent job should now succeed, even though we're missing a local dependency" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "dependencies/dependentOnly.nix"
    );

    ok(runBuild($builds->{"dependentJob"}), "building the job should succeed");
};


done_testing;
