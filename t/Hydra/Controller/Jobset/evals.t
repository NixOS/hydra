use strict;
use warnings;
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

ok(evalSucceeds($jobset), "Evaluating jobs/basic.nix should exit with return code 0");

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
