use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request;
use HTTP::Request::Common;
use JSON::MaybeXS qw(decode_json encode_json);

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
    build      => 1
);

my $queuedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build      => 0
);

subtest "/api/queue" => sub {
    my $response = request(GET '/api/queue?nr=1');
    ok($response->is_success, "The API enpdoint showing the queue returns 200.");

    my $data  = is_json($response);
    my $build = $queuedBuilds->{"one_job"};
    like(
        $data,
        [
            {
                priority => $build->priority,
                id       => $build->id,
            }
        ]
    );
};

subtest "/api/latestbuilds" => sub {
    subtest "with no specific parameters" => sub {
        my $response = request(GET '/api/latestbuilds?nr=1');
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data  = is_json($response);
        my $build = $finishedBuilds->{"one_job"};
        like(
            $data,
            [
                {
                    buildstatus => $build->buildstatus,
                    id          => $build->id,
                }
            ]
        );
    };

    subtest "with very specific parameters" => sub {
        my $build       = $finishedBuilds->{"one_job"};
        my $projectName = $build->project->name;
        my $jobsetName  = $build->jobset->name;
        my $jobName     = $build->job;
        my $system      = $build->system;
        my $response =
          request(GET "/api/latestbuilds?nr=1&project=$projectName&jobset=$jobsetName&job=$jobName&system=$system");
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);

        like(
            $data,
            [
                {
                    buildstatus => $build->buildstatus,
                    id          => $build->id,
                }
            ]
        );
    };
};

subtest "/api/nrbuilds" => sub {
    subtest "with no specific parameters" => sub {
        my $response = request(GET '/api/nrbuilds?nr=1&period=hour');
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);
        is($data, [1]);
    };

    subtest "with very specific parameters" => sub {
        my $build       = $finishedBuilds->{"one_job"};
        my $projectName = $build->project->name;
        my $jobsetName  = $build->jobset->name;
        my $jobName     = $build->job;
        my $system      = $build->system;
        my $response    = request(
            GET "/api/nrbuilds?nr=1&period=hour&project=$projectName&jobset=$jobsetName&job=$jobName&system=$system");
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);
        is($data, [1]);
    };
};

subtest "/api/push" => sub {
    subtest "with a specific jobset" => sub {
        my $build       = $finishedBuilds->{"one_job"};
        my $jobset      = $build->jobset;
        my $projectName = $jobset->project->name;
        my $jobsetName  = $jobset->name;
        is($jobset->forceeval, undef, "The existing jobset is not set to be forced to eval");

        my $response = request(GET "/api/push?jobsets=$projectName:$jobsetName&force=1");
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => ["$projectName:$jobsetName"] });

        my $updatedJobset = $ctx->db->resultset('Jobsets')->find({ id => $jobset->id });
        is($updatedJobset->forceeval, 1, "The jobset is now forced to eval");
    };

    subtest "with a specific source" => sub {
        my $repo    = $ctx->jobsdir;
        my $jobsetA = $queuedBuilds->{"one_job"}->jobset;
        my $jobsetB = $finishedBuilds->{"one_job"}->jobset;

        is($jobsetA->forceeval, undef, "The existing jobset is not set to be forced to eval");

        print STDERR $repo;

        my $response = request(GET "/api/push?repos=$repo&force=1");
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is(
            $data,
            {
                jobsetsTriggered => [
                    "${\$jobsetA->project->name}:${\$jobsetA->name}", "${\$jobsetB->project->name}:${\$jobsetB->name}"
                ]
            }
        );

        my $updatedJobset = $ctx->db->resultset('Jobsets')->find({ id => $jobsetA->id });
        is($updatedJobset->forceeval, 1, "The jobset is now forced to eval");
    };
};

subtest "/api/push-github" => sub {

    # Create a project and jobset which looks like it comes from GitHub
    my $user = $ctx->db()->resultset('Users')->create(
        {
            username     => "api-push-github",
            emailaddress => 'api-push-github@example.org',
            password     => ''
        }
    );

    my $project = $ctx->db()->resultset('Projects')->create(
        {
            name        => "api-push-github",
            displayname => "api-push-github",
            owner       => $user->username
        }
    );

    subtest "with a legacy input type" => sub {
        my $jobset = $project->jobsets->create(
            {
                name          => "legacy-input-type",
                nixexprinput  => "src",
                nixexprpath   => "default.nix",
                emailoverride => ""
            }
        );

        my $jobsetinput = $jobset->jobsetinputs->create({ name => "src", type => "git" });
        $jobsetinput->jobsetinputalts->create({ altnr => 0, value => "https://github.com/OWNER/LEGACY-REPO.git" });

        my $req = POST '/api/push-github',
          "Content-Type" => "application/json",
          "Content"      => encode_json(
            {
                repository => {
                    owner => {
                        name => "OWNER",
                    },
                    name => "LEGACY-REPO",
                }
            }
          );

        my $response = request($req);
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => ["api-push-github:legacy-input-type"] }, "The correct jobsets are triggered.");
    };

    subtest "with a flake input type" => sub {
        my $jobset = $project->jobsets->create(
            {
                name          => "flake-input-type",
                type          => 1,
                flake         => "github:OWNER/FLAKE-REPO",
                emailoverride => ""
            }
        );

        my $req = POST '/api/push-github',
          "Content-Type" => "application/json",
          "Content"      => encode_json(
            {
                repository => {
                    owner => {
                        name => "OWNER",
                    },
                    name => "FLAKE-REPO",
                }
            }
          );

        my $response = request($req);
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => ["api-push-github:flake-input-type"] }, "The correct jobsets are triggered.");
    };
};

done_testing;
