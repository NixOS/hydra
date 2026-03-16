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
my $project = $build->project;

subtest "/project/PROJECT/all" => sub {
    my $response = request(GET '/project/' . $project->name . '/all');
    ok($response->is_success, "The page showing the project's builds returns 200.");
};

subtest "/project/PROJECT/channel/latest" => sub {
    my $response = request(GET '/project/' . $project->name . '/channel/latest');
    ok($response->is_success, "The page showing the project's builds returns 200.");
};

done_testing;
