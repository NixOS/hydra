use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
use Hydra::Event;
use Hydra::Event::StepFinished;

use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({ name => "tests", displayname => "", owner => "root" });
my $jobset  = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset), "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '" . $build->job . "' from jobs/basic.nix should exit with return code 0");
}

subtest "Parsing step_finished" => sub {
    like(dies { Hydra::Event::parse_payload("step_finished", "") },               qr/three arguments/, "empty payload");
    like(dies { Hydra::Event::parse_payload("step_finished", "abc123") },         qr/three arguments/, "one argument");
    like(dies { Hydra::Event::parse_payload("step_finished", "abc123\tabc123") }, qr/three arguments/, "two arguments");
    like(
        dies { Hydra::Event::parse_payload("step_finished", "abc123\tabc123\tabc123\tabc123") },
        qr/three arguments/,
        "four arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("step_finished", "abc123\t123\t/path/to/log") },
        qr/should be an integer/,
        "not an integer: first position"
    );
    like(
        dies { Hydra::Event::parse_payload("step_finished", "123\tabc123\t/path/to/log") },
        qr/should be an integer/,
        "not an integer: second argument"
    );
    is(
        Hydra::Event::parse_payload("step_finished", "123\t456\t/path/to/logfile"),
        Hydra::Event::StepFinished->new(123, 456, "/path/to/logfile")
    );
};

subtest "interested" => sub {
    my $event = Hydra::Event::StepFinished->new(123, []);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock   = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock   = mock_obj $plugin => (
            add => [
                "stepFinished" => sub { }
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {

    my $step  = $db->resultset('BuildSteps')->search({}, { limit => 1 })->next;
    my $build = $step->build;

    my $event = Hydra::Event::StepFinished->new($build->id, $step->stepnr, "/foo/bar/baz");

    $event->load($db);
    is($event->{"step"}->get_column("build"), $build->id, "The build record matches.");

    # Create a fake "plugin" with a stepFinished sub, the sub sets this
    # "global" passedStep, passedLogPath variables.
    my $passedStep;
    my $passedLogPath;
    my $plugin = {};
    my $mock   = mock_obj $plugin => (
        add => [
            "stepFinished" => sub {
                my ($self, $step, $log_path) = @_;
                $passedStep    = $step;
                $passedLogPath = $log_path;
            }
        ]
    );

    $event->execute($db, $plugin);

    is($passedStep->get_column("build"),
        $build->id, "The plugin's stepFinished hook is called with a step from the expected build");
    is($passedStep->stepnr, $step->stepnr,
        "The plugin's stepFinished hook is called with the proper step of the build");
    is($passedLogPath, "/foo/bar/baz", "The plugin's stepFinished hook is called with the proper log path");
};

done_testing;
