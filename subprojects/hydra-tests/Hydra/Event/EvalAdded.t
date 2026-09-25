use strict;
use warnings;
use Setup;
use Hydra::Event;
use Hydra::Event::EvalAdded;
use Test2::V0;
use Test2::Tools::Exception;
use Test2::Tools::Mock qw(mock_obj);


my $ctx = test_context();
my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);


subtest "Parsing eval_added" => sub {
    like(
        dies { Hydra::Event::parse_payload("eval_added", "") },
        qr/four arguments/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123") },
        qr/four arguments/,
        "one argument"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123") },
        qr/four arguments/,
        "two arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123\tabc123") },
        qr/four arguments/,
        "three arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123\tabc123\tabc123\tabc123") },
        qr/four arguments/,
        "five arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123\t123\t0") },
        qr/should be an integer/,
        "not an integer: second position"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\t123\tabc123\t0") },
        qr/should be an integer/,
        "not an integer: third position"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\t123\t456\tabc123") },
        qr/should be 0 or 1/,
        "not a flag: fourth position"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\t123\t456\t2") },
        qr/should be 0 or 1/,
        "out of range: fourth position"
    );
    is(
        Hydra::Event::parse_payload("eval_added", "abc123\t123\t456\t1"),
        Hydra::Event::EvalAdded->new("abc123", 123, 456, 1)
    );
};

subtest "interested" => sub {
    my $event = Hydra::Event::EvalAdded->new("abc123", 123, 456, 0);

    subtest "A plugin which does not implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => ();

        is($event->interestedIn($plugin), 0, "The plugin is not interesting.");
    };

    subtest "A plugin which does implement the API" => sub {
        my $plugin = {};
        my $mock = mock_obj $plugin => (
            add => [
                "evalAdded" => sub {}
            ]
        );

        is($event->interestedIn($plugin), 1, "The plugin is interesting.");
    };
};

subtest "load" => sub {
    my $jobset = $builds->{"empty_dir"}->jobset;
    my $evaluation = $builds->{"empty_dir"}->jobsetevals->first();

    my $event = Hydra::Event::EvalAdded->new("traceID", $jobset->id, $evaluation->id, 1);

    $event->load($ctx->db());
    is($event->{"trace_id"}, "traceID", "The Trace ID matches");
    is($event->{"jobset_id"}, $jobset->id, "The Jobset ID matches");
    is($event->{"evaluation_id"}, $evaluation->id, "The Evaluation ID matches");


    # Create a fake "plugin" with a evalAdded sub, the sub sets these
    # "globals"
    my $passedTraceID;
    my $passedJobset;
    my $passedEvaluation;
    my $passedErrorChanged;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "evalAdded" => sub {
                my ($self, $traceID, $jobset, $evaluation, $errorChanged) = @_;
                $passedTraceID = $traceID;
                $passedJobset = $jobset;
                $passedEvaluation = $evaluation;
                $passedErrorChanged = $errorChanged;
            }
        ]
    );

    $event->execute($ctx->db(), $plugin);
    is($passedTraceID, "traceID", "We get the expected trace ID");
    is($passedJobset->id, $jobset->id, "The correct jobset is passed");
    is($passedEvaluation->id, $evaluation->id, "The correct evaluation is passed");
    is($passedErrorChanged, 1, "The plugin is told the jobset's error changed");
};

done_testing;
