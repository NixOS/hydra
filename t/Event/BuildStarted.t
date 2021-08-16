use strict;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
use Hydra::Event;
use Hydra::Event::BuildStarted;

use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

subtest "Parsing build_started" => sub {
    like(
        dies { Hydra::Event::parse_payload("build_started", "") },
        qr/one argument/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("build_started", "abc123\tabc123") },
        qr/only one argument/,
        "two arguments"
    );

    like(
        dies { Hydra::Event::parse_payload("build_started", "abc123") },
        qr/should be an integer/,
        "not an integer"
    );
    is(
        Hydra::Event::parse_payload("build_started", "19"),
        Hydra::Event::BuildStarted->new(19),
        "Valid parse"
    );
};

subtest "load" => sub {
    my $build = $db->resultset('Builds')->search(
      { },
      { limit => 1 }
    )->next;

    my $event = Hydra::Event::BuildStarted->new($build->id);

    $event->load($db);

    is($event->{"build"}->id, $build->id, "The build record matches.");

    # Create a fake "plugin" with a buildStarted sub, the sub sets this
    # global passedBuild variable.
    my $passedBuild;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "buildStarted" => sub {
                my ($self, $build) = @_;
                $passedBuild = $build;
            }
        ]
    );

    $event->execute($db, $plugin);

    is($passedBuild->id, $build->id, "The plugin's buildStarted hook is called with the proper build");
};

done_testing;
