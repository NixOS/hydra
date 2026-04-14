use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);

use JSON::MaybeXS;

use HTTP::Request::Common;
use Test2::V0;
setup_catalyst_test($ctx{context});

require Hydra::Schema;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/content-addressed.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 14, "Evaluating jobs/content-addressed.nix should result in 14 builds");

my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx{context}, @builds), "Building all jobs from jobs/content-addressed.nix should exit with code 0");

for my $build (@builds) {
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' from jobs/content-addressed.nix should be finished.");
    my $expected = $build->job eq "fails" ? 1 : $build->job =~ /with_failed/ ? 6 : $build->job =~ /FailingCA/ ? 2 : 0;
    is($newbuild->buildstatus, $expected, "Build '".$build->job."' from jobs/content-addressed.nix should have buildstatus $expected.");

    my $response = request("/build/".$build->id);
    ok($response->is_success, "The 'build' page for build '".$build->job."' should load properly");

    if ($newbuild->buildstatus == 0) {
      my $buildOutputs = $newbuild->buildoutputs;
      for my $output ($newbuild->buildoutputs) {
        # XXX: This hardcodes /nix/store/.
        # It's fine because in practice the nix store for the tests will be of
        # the form `/some/thing/nix/store/`, but it would be cleaner if there
        # was a way to query Nix for its store dir?
        like(
          $output->path, qr|/nix/store/|,
          "Output '".$output->name."' of build '".$build->job."' should be a valid store path"
        );
      }
    }

}

# XXX: deststoredir is undefined: Use of uninitialized value $ctx{"deststoredir"} in concatenation (.) or string at t/content-addressed/basic.t line 58.
# XXX: This test seems to not do what it seems to be doing. See documentation: https://metacpan.org/pod/Test2::V0#isnt($got,-$do_not_want,-$name)
isnt(<$ctx{deststoredir}/realisations/*>, "", "The destination store should have the realisations of the built derivations registered");

# Early cutoff: earlyCutoffUpstream1 and earlyCutoffUpstream2 have
# different derivations but produce the same content-addressed output.
# After building earlyCutoffDownstream1, earlyCutoffDownstream2 should
# be cached because its resolved input is identical.
my $upstream1 = $db->resultset('Builds')->find({
    jobset_id => $jobset->id,
    job => "earlyCutoffUpstream1",
});
my $upstream2 = $db->resultset('Builds')->find({
    jobset_id => $jobset->id,
    job => "earlyCutoffUpstream2",
});

my $upstream1_out = $upstream1->buildoutputs->find({ name => "out" });
my $upstream2_out = $upstream2->buildoutputs->find({ name => "out" });
is($upstream1_out->path, $upstream2_out->path,
    "Both upstream builds should resolve to the same content-addressed output path");

my $downstream1 = $db->resultset('Builds')->find({
    jobset_id => $jobset->id,
    job => "earlyCutoffDownstream1",
});
my $downstream2 = $db->resultset('Builds')->find({
    jobset_id => $jobset->id,
    job => "earlyCutoffDownstream2",
});

my $downstream1_out = $downstream1->buildoutputs->find({ name => "out" });
my $downstream2_out = $downstream2->buildoutputs->find({ name => "out" });
is($downstream1_out->path, $downstream2_out->path,
    "Both downstream builds should resolve to the same content-addressed output path");

# TODO: Once the queue runner deduplicates steps by resolved derivation
# path (not just original drv path), we should also verify that both
# original steps resolve to steps with the same derivation. (Might even
# be the same step, but that doesn't matter as much).
#
# If there are multiple steps for the single resolved derivation,
# additionally, only one should get built, and the other should be a
# cached successes (as is normal for duplicative build steps).

done_testing;

