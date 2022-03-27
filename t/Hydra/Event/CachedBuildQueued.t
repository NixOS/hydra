use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
use Hydra::Event;
use Hydra::Event::CachedBuildQueued;

use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

subtest "Parsing" => sub {
    like(
        dies { Hydra::Event::parse_payload("cached_build_queued", "") },
        qr/takes two arguments/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("cached_build_queued", "abc123") },
        qr/takes two arguments/,
        "missing the build ID"
    );

    like(
        dies { Hydra::Event::parse_payload("cached_build_queued", "123\t456\t789\t012\t345") },
        qr/takes two arguments/,
        "too many arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("cached_build_queued", "abc123\tdef456") },
        qr/should be integers/,
        "evaluation ID should be an integer"
    );
    like(
        dies { Hydra::Event::parse_payload("cached_build_queued", "123\tabc123") },
        qr/should be integers/,
        "build ID should be an integer"
    );
    is(
        Hydra::Event::parse_payload("cached_build_queued", "123\t456"),
        Hydra::Event::CachedBuildQueued->new(123, 456),
        "one dependent build"
    );
};

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

subtest "interested" => sub {
    my $event = Hydra::Event::CachedBuildQueued->new(123, 456);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => (
            add => [
                "cachedBuildQueued" => sub {}
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {
    my ($build) = $db->resultset('Builds')->search({ }, { limit => 1 })->single;
    my $evaluation = $build->jobsetevals->search({}, { limit => 1 })->single;

    my $event = Hydra::Event::CachedBuildQueued->new($evaluation->id, $build->id);

    $event->load($db);
    is($event->{"evaluation"}->id, $evaluation->id, "The evaluation record matches.");
    is($event->{"build"}->id, $build->id, "The build record matches.");

    # Create a fake "plugin" with a cachedBuildQueued sub, the sub sets this
    # global passedEvaluation and passedBuild variables for verifying.
    my $passedEvaluation;
    my $passedBuild;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "cachedBuildQueued" => sub {
                my ($self, $evaluation, $build) = @_;
                $passedEvaluation = $evaluation;
                $passedBuild = $build;
            }
        ]
    );

    $event->execute($db, $plugin);

    is($passedEvaluation->id, $evaluation->id, "The plugin's cachedBuildQueued hook is called with a matching evaluation");
    is($passedBuild->id, $build->id, "The plugin's cachedBuildQueued hook is called with a matching build");
};

done_testing;
