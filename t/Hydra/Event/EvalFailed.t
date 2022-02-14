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
    build      => 1
);

subtest "Parsing eval_failed" => sub {
    like(dies { Hydra::Event::parse_payload("eval_failed", "") },       qr/two arguments/, "empty payload");
    like(dies { Hydra::Event::parse_payload("eval_failed", "abc123") }, qr/two arguments/, "one argument");
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\tabc123\tabc123") },
        qr/two arguments/,
        "three arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_failed", "abc123\tabc123") },
        qr/should be an integer/,
        "not an integer: second argument"
    );
    is(Hydra::Event::parse_payload("eval_failed", "abc123\t456"), Hydra::Event::EvalFailed->new("abc123", 456));
};

subtest "interested" => sub {
    my $event = Hydra::Event::EvalFailed->new(123, []);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock   = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock   = mock_obj $plugin => (
            add => [
                "evalFailed" => sub { }
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {
    my $jobset = $builds->{"empty_dir"}->jobset;

    my $event = Hydra::Event::EvalFailed->new("traceID", $jobset->id);

    $event->load($ctx->db());
    is($event->{"jobset"}->get_column("id"), $jobset->id, "The jobset record matches.");

    # Create a fake "plugin" with a evalFailed sub, the sub sets this
    # "global" passedTraceID, passedJobset
    my $passedTraceID;
    my $passedJobset;
    my $plugin = {};
    my $mock   = mock_obj $plugin => (
        add => [
            "evalFailed" => sub {
                my ($self, $traceID, $jobset) = @_;
                $passedTraceID = $traceID;
                $passedJobset  = $jobset;
            }
        ]
    );

    $event->execute($ctx->db(), $plugin);
    is($passedTraceID,                  "traceID",   "The plugin is told what the trace ID was");
    is($passedJobset->get_column("id"), $jobset->id, "The plugin's evalFailed hook is called with the right jobset");
};

done_testing;
