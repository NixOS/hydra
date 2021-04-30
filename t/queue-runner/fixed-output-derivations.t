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

my $nixSource = "fixed-output.nix";

my $jobset = createBaseJobset("fixed-output", $nixSource, $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/".$nixSource." should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 2, "Evaluating jobs/".$nixSource." should result in 2 builds");

my @builds = queuedBuildsForJobset($jobset);

subtest "valid fixed-output derivation" => sub {
    my ($build) = grep { $_->nixname eq "fixed-output" } @builds;
    ok(runBuild($build), "Build should exit with code 0");

    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");
};

subtest "fixed-output derivation with a wrong hash" => sub {
    my ($build) = grep { $_->nixname eq "wrong-hash" } @builds;
    ok(runBuild($build), "Build should exit with code 0");

    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 1, "Build should have buildstatus 1.");

    my $latestBuildStep = ($newbuild->buildsteps)[0];
    like($latestBuildStep->errormsg, qr/hash mismatch/, "The hash mismatch should be properly reported");
};

done_testing;

