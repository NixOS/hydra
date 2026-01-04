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
        qr/three arguments/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123") },
        qr/three arguments/,
        "one argument"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123") },
        qr/three arguments/,
        "two arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123\tabc123\tabc123") },
        qr/three arguments/,
        "four arguments"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\tabc123\t123") },
        qr/should be an integer/,
        "not an integer: second position"
    );
    like(
        dies { Hydra::Event::parse_payload("eval_added", "abc123\t123\tabc123") },
        qr/should be an integer/,
        "not an integer: third position"
    );
    is(
        Hydra::Event::parse_payload("eval_added", "abc123\t123\t456"),
        Hydra::Event::EvalAdded->new("abc123", 123, 456)
    );
};

subtest "interested" => sub {
    my $event = Hydra::Event::EvalAdded->new("abc123", 123, 456);

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

    my $event = Hydra::Event::EvalAdded->new("traceID", $jobset->id, $evaluation->id);

    $event->load($ctx->db());
    is($event->{"trace_id"}, "traceID", "The Trace ID matches");
    is($event->{"jobset_id"}, $jobset->id, "The Jobset ID matches");
    is($event->{"evaluation_id"}, $evaluation->id, "The Evaluation ID matches");


    # Create a fake "plugin" with a evalAdded sub, the sub sets these
    # "globals"
    my $passedTraceID;
    my $passedJobset;
    my $passedEvaluation;
    my $plugin = {};
    my $mock = mock_obj $plugin => (
        add => [
            "evalAdded" => sub {
                my ($self, $traceID, $jobset, $evaluation) = @_;
                $passedTraceID = $traceID;
                $passedJobset = $jobset;
                $passedEvaluation = $evaluation;
            }
        ]
    );

    $event->execute($ctx->db(), $plugin);
    is($passedTraceID, "traceID", "We get the expected trace ID");
    is($passedJobset->id, $jobset->id, "The correct jobset is passed");
    is($passedEvaluation->id, $evaluation->id, "The correct evaluation is passed");
};

done_testing;
