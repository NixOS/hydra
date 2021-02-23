use strict;
use Cwd;
use Setup;

(my $datadir, my $pgsql) = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Test jobset with 2 jobs, one has parameter of succeeded build of the other
my $jobset = createJobsetWithOneInput("build-output-as-input", "build-output-as-input.nix", "build1", "build", "build1");

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for first time should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/basic.nix should have buildstatus 0");
}

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix for second time should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for second time after building build1 should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/basic.nix should have buildstatus 0");
}

done_testing;
