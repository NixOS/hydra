use strict;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Test jobset with 2 jobs, one has parameter of succeeded build of the other
my $jobset = createJobsetWithOneInput("build-output-as-input", "build-output-as-input.nix", "build1", "build", "build1", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/build-output-as-input.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1 , "Evaluation should result in 1 build in queue");

subtest "For the 'build1' job" => sub {
    my ($build) = queuedBuildsForJobset($jobset);
    is($build->job, "build1", "Verify the only job we got is for 'build1'");

    ok(runBuild($build), "Build should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");
};

ok(evalSucceeds($jobset), "Evaluating jobs/build-output-as-input.nix for second time should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1 , "The second evaluation should result in 1 new build in queue: build2");
subtest "For the 'build2' job" => sub {
    my ($build) = queuedBuildsForJobset($jobset);
    is($build->job, "build2", "Verify the only job we got is for 'build2'");

    ok(runBuild($build), "Build should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");
};

done_testing;
