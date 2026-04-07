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

subtest "/jobset/PROJECT/JOBSET" => sub {
    my $jobset = request(GET '/jobset/' . $project->name . '/' . $jobset->name);
    ok($jobset->is_success, "The page showing the jobset returns 200.");
};

subtest "/jobset/PROJECT/JOBSET/evals" => sub {
    my $jobsetevals = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/evals');
    ok($jobsetevals->is_success, "The page showing the jobset evals returns 200.");
};

subtest "/jobset/PROJECT/JOBSET/errors" => sub {
    my $jobsetevals = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/errors');
    ok($jobsetevals->is_success, "The page showing the jobset eval errors returns 200.");
};

done_testing;
