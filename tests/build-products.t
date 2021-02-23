use strict;
use Cwd;
use Setup;

(my $datadir, my $pgsql) = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);


# Test build products

my $jobset = createBaseJobset("build-products", "build-products.nix");

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-products.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 2 , "Evaluating jobs/build-products.nix should result in 2 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/build-products.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/build-products.nix should have buildstatus 0");

    my $buildproducts = $db->resultset('BuildProducts')->search({ build => $build->id });
    my $buildproduct = $buildproducts->next;

    if($build->job eq "simple") {
        ok($buildproduct->name eq "text.txt", "We should have text.txt, but found: ".$buildproduct->name."\n");
    } elsif ($build->job eq "with_spaces") {
        ok($buildproduct->name eq "some text.txt", "We should have: \"some text.txt\", but found: ".$buildproduct->name."\n");
    }
}

done_testing;
