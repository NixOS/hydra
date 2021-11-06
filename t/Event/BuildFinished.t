use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
use Hydra::Event;
use Hydra::Event::BuildFinished;

use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

subtest "Parsing" => sub {
    like(
        dies { Hydra::Event::parse_payload("build_finished", "") },
        qr/at least one argument/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("build_finished", "abc123") },
        qr/should be integers/,
        "build ID should be an integer"
    );
    like(
        dies { Hydra::Event::parse_payload("build_finished", "123\tabc123") },
        qr/should be integers/,
        "dependent ID should be an integer"
    );
    is(
        Hydra::Event::parse_payload("build_finished", "123"),
        Hydra::Event::BuildFinished->new(123, []),
        "no dependent builds"
    );
    is(
        Hydra::Event::parse_payload("build_finished", "123\t456"),
        Hydra::Event::BuildFinished->new(123, [456]),
        "one dependent build"
    );
    is(
        Hydra::Event::parse_payload("build_finished", "123\t456\t789\t012\t345"),
        Hydra::Event::BuildFinished->new(123, [456, 789, 12, 345]),
        "four dependent builds"
    );
};

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

subtest "load" => sub {
    my ($build, $dependent_a, $dependent_b) = $db->resultset('Builds')->search(
      { },
      { limit => 3 }
    )->all;

    my $event = Hydra::Event::BuildFinished->new($build->id, [$dependent_a->id, $dependent_b->id]);

    $event->load($db);

    is($event->{"build"}->id, $build->id, "The build record matches.");
    is($event->{"dependents"}[0]->id, $dependent_a->id, "The dependent_a record matches.");
    is($event->{"dependents"}[1]->id, $dependent_b->id, "The dependent_b record matches.");

    # Create a fake "plugin" with a buildFinished sub, the sub sets this
    # global passedBuild and passedDependents variables for verifying.
    my $passedBuild;
    my $passedDependents;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "buildFinished" => sub {
                my ($self, $build, $dependents) = @_;
                $passedBuild = $build;
                $passedDependents = $dependents;
            }
        ]
    );

    $event->execute($db, $plugin);

    is($passedBuild->id, $build->id, "The plugin's buildFinished hook is called with a matching build");
    is($passedDependents->[0]->id, $dependent_a->id, "The plugin's buildFinished hook is called with a matching dependent_a");
    is($passedDependents->[1]->id, $dependent_b->id, "The plugin's buildFinished hook is called with a matching dependent_b");
};

done_testing;
