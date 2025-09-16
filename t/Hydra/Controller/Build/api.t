use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);
use Data::Dumper;
use URI;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;

my %ctx = test_init();

Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("aggregate", "aggregate.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/aggregate.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/aggregate.nix should result in 3 builds");
my $aggregateBuild;
for my $build (queuedBuildsForJobset($jobset)) {
    if ($build->nixname eq "aggregate") {
        $aggregateBuild = $build;
    }
    ok(runBuild($build), "Build '".$build->job."' from jobs/aggregate.nix should exit with return code 0");
}
$aggregateBuild->discard_changes();

my $build_redirect = request(GET '/job/tests/aggregate/aggregate/latest-finished');
my $build_url = URI->new($build_redirect->header('location'))->path;

subtest "validating the JSON representation of a build" => sub {
    my $response = request(GET $build_url,
        Accept => 'application/json',
    );

    is($response->code, 200, "Getting the build data");

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }

    is($data, {
        project => "tests",
        jobset => "aggregate",
        buildmetrics => {},
        buildoutputs => { out => { path => $aggregateBuild->buildoutputs->find({ name => "out" })->path }},
        buildproducts => { 1 => { 
            defaultpath => "",
            filesize => undef,
            name => "aggregate",
            path => $aggregateBuild->buildoutputs->find({ name => "out" })->path,
            sha256hash => undef,
            subtype => "",
            type => "nix-build",
         }},
        buildstatus => 0,
        drvpath => $aggregateBuild->drvpath,
        finished => 1,
        id => $aggregateBuild->id,
        job => "aggregate",
        nixname => "aggregate",
        priority => 100,
        releasename => undef,
        starttime => $aggregateBuild->starttime,
        stoptime => $aggregateBuild->stoptime,
        timestamp => $aggregateBuild->timestamp,
        system => $aggregateBuild->system,
    }, "The build's JSON matches our API.");
};

subtest "accessing the constituents API" => sub {
    my $url = $build_url . "/constituents";

    my $constituents = request(GET $url,
        Accept => 'application/json',
    );

    ok($constituents->is_success, "Getting the constituent builds");

    my $data;
    my $valid_json = lives { $data = decode_json($constituents->content); };
    ok($valid_json, "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $constituents->content;
    }

    my ($buildA) = grep { $_->{nixname} eq "empty-dir-a" } @$data;
    my ($buildB) = grep { $_->{nixname} eq "empty-dir-b" } @$data;

    is($buildA->{job}, "a");
    is($buildB->{job}, "b");
};

done_testing;
