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

subtest "/queue-runner-status" => sub {
    my $global = request(GET '/queue-runner-status');
    ok($global->is_success, "The page showing the the queue runner status 200's.");
};

done_testing;
