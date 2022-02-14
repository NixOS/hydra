use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build      => 1
);

my $build   = $builds->{"empty_dir"};
my $project = $build->project;
my $jobset  = $build->jobset;

subtest "/jobset/PROJECT/JOBSET/all" => sub {
    my $response = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/all');
    ok($response->is_success, "The page showing the jobset's builds returns 200.");
};

subtest "/jobset/PROJECT/JOBSET/channel/latest" => sub {
    my $response = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/channel/latest');
    ok($response->is_success, "The page showing the jobset's builds returns 200.");
};

done_testing;
