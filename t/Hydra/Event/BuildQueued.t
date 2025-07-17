use strict;
use warnings;
use Setup;
use Hydra::Event;
use Hydra::Event::BuildQueued;
use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $ctx = test_context();

my $db = $ctx->db();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix"
);

subtest "Parsing build_queued" => sub {
    like(
        dies { Hydra::Event::parse_payload("build_queued", "") },
        qr/one argument/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("build_queued", "abc123\tabc123") },
        qr/only one argument/,
        "two arguments"
    );

    like(
        dies { Hydra::Event::parse_payload("build_queued", "abc123") },
        qr/should be an integer/,
        "not an integer"
    );
    is(
        Hydra::Event::parse_payload("build_queued", "19"),
        Hydra::Event::BuildQueued->new(19),
        "Valid parse"
    );
};

subtest "interested" => sub {
    my $event = Hydra::Event::BuildQueued->new(123, []);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => (
            add => [
                "buildQueued" => sub {}
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {
    my $build = $builds->{"empty_dir"};

    my $event = Hydra::Event::BuildQueued->new($build->id);

    $event->load($db);

    is($event->{"build"}->id, $build->id, "The build record matches.");

    # Create a fake "plugin" with a buildQueued sub, the sub sets this
    # global passedBuild variable.
    my $passedBuild;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "buildQueued" => sub {
                my ($self, $build) = @_;
                $passedBuild = $build;
            }
        ]
    );

    $event->execute($db, $plugin);

    is($passedBuild->id, $build->id, "The plugin's buildQueued hook is called with the proper build");
};

done_testing;
