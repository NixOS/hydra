use feature 'unicode_strings';
use strict;
use Setup;

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),                  "Evaluating jobs/content-addressed.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/content-addressed.nix should result in 3 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/content-addressed.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' from jobs/content-addressed.nix should be finished.");
    my $expected = $build->job eq "fails" ? 1 : $build->job =~ /with_failed/ ? 6 : 0;
    is($newbuild->buildstatus, $expected, "Build '".$build->job."' from jobs/content-addressed.nix should have buildstatus $expected.");
}


done_testing;

