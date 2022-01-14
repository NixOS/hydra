use strict;
use warnings;
use Setup;
use Data::Dumper;
use Test2::V0;
use JSON::MaybeXS qw(decode_json);
use Catalyst::Test ();
use HTTP::Request::Common;

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $doneBuilds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

my $queuedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix"
);

subtest "/machines" => sub {
    my $response = request(GET '/machines');
    ok($response->is_success, "The page showing the machine status 200's.");
};

subtest "/queue-runner-status" => sub {
    my $global = request(GET '/queue-runner-status');
    ok($global->is_success, "The page showing the queue runner status 200's.");
};

subtest "/queue-summary" => sub {
    my $response = request(GET '/queue-summary');
    ok($response->is_success, "The page showing the queue summary 200's.");
};

subtest "/queue" => sub {
    my $response = request(GET '/queue', Accept => 'application/json');
    ok($response->is_success, "The page showing the queue 200's.");

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }
};

subtest "/search" => sub {
    my $build = $doneBuilds->{"empty_dir"};
    my ($build_output_out) = $build->buildoutputs->find({ name => "out" });
    subtest "searching for projects" => sub {
        my $response = request(GET "/search?query=${\$build->project->name}");
        is($response->code, 200, "The search page 200's.");
    };

    subtest "searching for jobsets" => sub {
        my $response = request(GET "/search?query=${\$build->jobset->name}");
        is($response->code, 200, "The search page 200's.");
    };

    subtest "searching for jobs" => sub {
        my $response = request(GET "/search?query=${\$build->job}");
        is($response->code, 200, "The search page 200's.");
    };

    subtest "searching for output paths" => sub {
        my $response = request(GET "/search?query=${\$build_output_out->path}");
        is($response->code, 200, "The search page 200's.");
    };

    subtest "searching for derivation path" => sub {
        my $response = request(GET "/search?query=${\$build->drvpath}");
        is($response->code, 200, "The search page 200's.");
    };
};

subtest "/status" => sub {
    my $response = request(GET '/status', Accept => 'application/json');
    ok($response->is_success, "The page showing the status 200's.");

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }
};

subtest "/steps" => sub {
    my $response = request(GET '/steps');
    is($response->code, 200, "The page showing steps 200's.");
};

subtest "/evals" => sub {
    my $response = request(GET '/evals');
    is($response->code, 200, "The page showing evals 200's.");
};

done_testing;
