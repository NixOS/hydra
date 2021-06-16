use strict;
use Setup;
use Data::Dumper;
my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
use HTTP::Request::Common;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");
my ($build, @builds) = queuedBuildsForJobset($jobset);

ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with return code 0");

subtest "/build/ID/evals" => sub {
    my $evals = request(GET '/build/' . $build->id . '/evals');
    ok($evals->is_success, "The page listing evaluations this build is part of returns 200.");
};

done_testing;
