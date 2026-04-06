use strict;
use warnings;
use Setup;
use Data::Dumper;
my %ctx = test_init();

use Test2::V0;
use HTTP::Request::Common;
setup_catalyst_test($ctx{context});

require Hydra::Schema;
require Hydra::Helper::Nix;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");
my ($build, @builds) = queuedBuildsForJobset($jobset);

ok(runBuild($ctx{context}, $build), "Build '".$build->job."' from jobs/basic.nix should exit with return code 0");

subtest "/build/ID/evals" => sub {
    my $evals = request(GET '/build/' . $build->id . '/evals');
    ok($evals->is_success, "The page listing evaluations this build is part of returns 200.");
};

done_testing;
