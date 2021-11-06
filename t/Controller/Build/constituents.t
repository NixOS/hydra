use strict;
use warnings;
use Setup;
use JSON qw(decode_json encode_json);
use Data::Dumper;
use URI;
my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("aggregate", "aggregate.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/aggregate.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/aggregate.nix should result in 3 builds");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/aggregate.nix should exit with return code 0");
}

my $build_redirect = request(GET '/job/tests/aggregate/aggregate/latest-finished');

my $url = URI->new($build_redirect->header('location'))->path . "/constituents";
my $constituents = request(GET $url,
      Accept => 'application/json',
  );

ok($constituents->is_success, "Getting the constituent builds");
my $data = decode_json($constituents->content);

my ($buildA) = grep { $_->{nixname} eq "empty-dir-a" } @$data;
my ($buildB) = grep { $_->{nixname} eq "empty-dir-b" } @$data;

is($buildA->{job}, "a");
is($buildB->{job}, "b");

done_testing;
