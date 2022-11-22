use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;
use JSON::MaybeXS qw(decode_json);

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

my $build = $builds->{"empty_dir"};
my $jobset = $build->jobset;
my $project = $build->project;

subtest "/job/PROJECT/JOBSET/JOB" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job);
    ok($response->is_success, "The page showing the job's overview data returns 200.");
};

subtest "/job/PROJECT/JOBSET/JOB/all" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/all');
    ok($response->is_success, "The page showing the job's builds returns 200.");
};

subtest "/job/PROJECT/JOBSET/JOB/channel/latest" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/channel/latest');
    ok($response->is_success, "The page showing the job's channel returns 200.");
};

subtest "/job/PROJECT/JOBSET/JOB/shield" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/shield');
    ok($response->is_success, "The page showing the job's shield returns 200.");

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }

    is($data->{"color"}, "green");
    is($data->{"label"}, "hydra build");
    is($data->{"message"}, "passing");
    is($data->{"schemaVersion"}, 1);
};

subtest "/job/PROJECT/JOBSET/JOB/prometheus" => sub {
    my $response = request(GET '/job/' . $project->name . '/' . $jobset->name . '/' . $build->job . '/prometheus');
    ok($response->is_success, "The page showing the job's prometheus data returns 200.");
    my $metrics = $response->content;

    ok($metrics =~ m/hydra_job_failed\{.*\} 0/);
    ok($metrics =~ m/hydra_job_completion_time\{.*\} [\d]+/);
    ok($metrics =~ m/hydra_build_closure_size\{.*\} 96/);
    ok($metrics =~ m/hydra_build_output_size\{.*\} 96/);
};

done_testing;
