use strict;
use warnings;
use Setup;
use Data::Dumper;
my %ctx = test_init();

use Test2::V0;
use HTTP::Request::Common;
use File::Temp qw(tempdir);
use JSON::MaybeXS qw(decode_json);
setup_catalyst_test($ctx{context});

require Hydra::Schema;
require Hydra::Helper::Nix;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/basic.nix should exit with return code 0");

subtest "/jobset/PROJECT/JOBSET" => sub {
    my $jobset = request(GET '/jobset/' . $project->name . '/' . $jobset->name);
    ok($jobset->is_success, "The page showing the jobset returns 200.");
};

subtest "/jobset/PROJECT/JOBSET/evals" => sub {
    my $jobsetevals = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/evals');
    ok($jobsetevals->is_success, "The page showing the jobset evals returns 200.");
};

subtest "/jobset/PROJECT/JOBSET/evals lists failed evaluations" => sub {
    my $brokenDir = tempdir(CLEANUP => 1);
    open(my $fh, ">", "$brokenDir/default.nix") or die "$!";
    print $fh "{ broken = throw \"no\"; }\n";
    close $fh;

    my $broken = createBaseJobset($db, "broken", "default.nix", $brokenDir);
    captureEvaluation($ctx{context}, $broken);

    $broken->update({ forceeval => 1 });
    captureEvaluation($ctx{context}, $broken);

    my @evals = $broken->jobsetevals->search({}, { order_by => "id ASC" })->all;
    is(scalar @evals, 2, "Both evaluations were recorded.");
    ok($_->evaluationerror->has_error, "The evaluation carries an error.") for @evals;

    my $response = request(
        GET('/jobset/' . $project->name . '/broken/evals', Accept => 'application/json'));
    ok($response->is_success, "The evaluation listing returns 200.");
    my $json = decode_json($response->decoded_content);
    is(scalar @{$json->{evals}}, 2, "Both failed evaluations are listed.");
};

subtest "/jobset/PROJECT/JOBSET/errors" => sub {
    my $jobsetevals = request(GET '/jobset/' . $project->name . '/' . $jobset->name . '/errors');
    ok($jobsetevals->is_success, "The page showing the jobset eval errors returns 200.");
};

done_testing;
