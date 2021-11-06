use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);


# Test build products

my $jobset = createBaseJobset("build-products", "build-products.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/build-products.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 2, "Evaluating jobs/build-products.nix should result in 2 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    subtest "For the build job '" . $build->job . "'" => sub {
        ok(runBuild($build), "Build should exit with return code 0");
        my $newbuild = $db->resultset('Builds')->find($build->id);

        is($newbuild->finished, 1, "Build should have finished");
        is($newbuild->buildstatus, 0, "Build should have buildstatus 0");

        my $buildproducts = $db->resultset('BuildProducts')->search({ build => $build->id });
        my $buildproduct = $buildproducts->next;

        if($build->job eq "simple") {
            is($buildproduct->name, "text.txt", "We should have \"text.txt\"");
        } elsif ($build->job eq "with_spaces") {
            is($buildproduct->name, "some text.txt", "We should have: \"some text.txt\"");
        }
    };

}

done_testing;
