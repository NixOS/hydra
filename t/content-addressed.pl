use feature 'unicode_strings';
use strict;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

$jobset = createBaseJobset("content-addressed", "content-addressed.nix");

ok(evalSucceeds($jobset),                  "Evaluating jobs/content-addressed.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 3 , "Evaluating jobs/content-addressed.nix should result in 3 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/content-addressed.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    my $expected = $build->job eq "fails" ? 1 : $build->job =~ /with_failed/ ? 6 : 0;
    ok($newbuild->finished == 1 && $newbuild->buildstatus == $expected, "Build '".$build->job."' from jobs/content-addressed.nix should have buildstatus $expected");
}


done_testing;

