use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);

use Test2::V0;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "content-addressed-early-cutoff", "content-addressed-early-cutoff.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating early cutoff jobs should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 4, "Should queue 4 early cutoff builds");

my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx{context}, @builds), "Building all early cutoff jobs should exit with code 0");

for my $build (@builds) {
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' should be finished.");
    is($newbuild->buildstatus, 0, "Build '".$build->job."' should have buildstatus 0.");
}

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
    "Both downstream builds should create the same content-addressed output path");

# Skip this for now because it is currently possible for neither to be marked
# cached. Further investigation is needed. Note that it is not clear that the
# derivation is being built twice in the neither-marked-cached case either!
#
#ok($downstream1->iscachedbuild || $downstream2->iscachedbuild,
#    "One downstream build should be cached");

done_testing;
