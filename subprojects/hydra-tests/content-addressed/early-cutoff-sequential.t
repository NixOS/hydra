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

my %builds = map { $_->job => $_ } queuedBuildsForJobset($jobset);

ok(runBuilds($ctx{context}, $builds{earlyCutoffUpstream1}, $builds{earlyCutoffDownstream1}),
    "Building the first upstream/downstream pair should exit with code 0");
ok(runBuilds($ctx{context}, $builds{earlyCutoffUpstream2}, $builds{earlyCutoffDownstream2}),
    "Building the second upstream/downstream pair should exit with code 0");

for my $job (sort keys %builds) {
    my $build = $db->resultset('Builds')->find($builds{$job}->id);
    is($build->finished, 1, "Build '$job' should be finished.");
    is($build->buildstatus, 0, "Build '$job' should have buildstatus 0.");
}

my $downstream1 = $db->resultset('Builds')->find($builds{earlyCutoffDownstream1}->id);
my $downstream2 = $db->resultset('Builds')->find($builds{earlyCutoffDownstream2}->id);

my $downstream1_out = $downstream1->buildoutputs->find({ name => "out" });
my $downstream2_out = $downstream2->buildoutputs->find({ name => "out" });
is($downstream1_out->path, $downstream2_out->path,
    "Both downstream builds should create the same content-addressed output path");

ok(!$downstream1->iscachedbuild, "The first downstream build should not be cached");
ok($downstream2->iscachedbuild, "The second downstream build should be cached");

done_testing;
