use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;
use JSON::MaybeXS qw(decode_json);

sub is_json {
    my ($response, $message) = @_;

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, $message // "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }

    return $data;
}

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $finishedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build => 1
);

my $queuedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build => 0
);

subtest "/api/queue" => sub {
    my $response = request(GET '/api/queue?nr=1');
    ok($response->is_success, "The API enpdoint showing the queue returns 200.");

    my $data = is_json($response);
    my $build = $queuedBuilds->{"one_job"};
    like($data, [{
        priority => $build->priority,
        id => $build->id,
    }]);
};

subtest "/api/latestbuilds" => sub {
    subtest "with no specific parameters" => sub {
        my $response = request(GET '/api/latestbuilds?nr=1');
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);
        my $build = $finishedBuilds->{"one_job"};
        like($data, [{
            buildstatus => $build->buildstatus,
            id => $build->id,
        }]);
    };

    subtest "with very specific parameters" => sub {
        my $build = $finishedBuilds->{"one_job"};
        my $projectName = $build->project->name;
        my $jobsetName = $build->jobset->name;
        my $jobName = $build->job;
        my $system = $build->system;
        my $response = request(GET "/api/latestbuilds?nr=1&project=$projectName&jobset=$jobsetName&job=$jobName&system=$system");
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);

        like($data, [{
            buildstatus => $build->buildstatus,
            id => $build->id,
        }]);
    };
};

done_testing;
