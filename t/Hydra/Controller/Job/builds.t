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
    build => 1
);

my $build = $builds->{"empty_dir"};
my $jobset = $build->jobset;
my $project = $build->project;

subtest "/job/PROJECT/JOBSET/JOB/all" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/all');
    ok($response->is_success, "The page showing the job's builds returns 200.");
};

subtest "/job/PROJECT/JOBSET/JOB/channel/latest" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/channel/latest');
    ok($response->is_success, "The page showing the job's channel returns 200.");
};

done_testing;
