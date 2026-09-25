use strict;
use warnings;
use Setup;
use Hydra::Event;
use Hydra::Event::EvalFailed;
use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

subtest "Parsing eval_failed" => sub {
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "") },
        qr/three arguments/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123") },
        qr/three arguments/,
        "one argument"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\tabc123") },
        qr/three arguments/,
        "two arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\tabc123\tabc123\tabc123") },
        qr/three arguments/,
        "four arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\tabc123\t0") },
        qr/should be an integer/,
        "not an integer: second argument"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\t456\tabc123") },
        qr/should be 0 or 1/,
        "not a flag: third argument"
    );
    is(
        Hydra::Event::parse_payload("eval_failed", "abc123\t456\t1"),
        Hydra::Event::EvalFailed->new("abc123", 456, 1)
    );
};

subtest "interested" => sub {
    my $event = Hydra::Event::EvalFailed->new(123, [], 0);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => (
            add => [
                "evalFailed" => sub {}
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {
    my $jobset = $builds->{"empty_dir"}->jobset;

    my $event = Hydra::Event::EvalFailed->new("traceID", $jobset->id, 1);

    $event->load($ctx->db());
    is($event->{"jobset"}->get_column("id"), $jobset->id, "The jobset record matches.");

    # Create a fake "plugin" with a evalFailed sub, the sub sets this
    # "global" passedTraceID, passedJobset
    my $passedTraceID;
    my $passedJobset;
    my $passedErrorChanged;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "evalFailed" => sub {
                my ($self, $traceID, $jobset, $errorChanged) = @_;
                $passedTraceID = $traceID;
                $passedJobset = $jobset;
                $passedErrorChanged = $errorChanged;
            }
        ]
    );

    $event->execute($ctx->db(), $plugin);
    is($passedTraceID, "traceID", "The plugin is told what the trace ID was");
    is($passedJobset->get_column("id"), $jobset->id, "The plugin's evalFailed hook is called with the right jobset");
    is($passedErrorChanged, 1, "The plugin is told the jobset's error changed");
};

done_testing;
