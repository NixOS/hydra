use strict;
use Hydra::Event;
use Hydra::Event::BuildFinished;
use Hydra::Event::BuildStarted;
use Hydra::Event::StepFinished;

use Test2::V0;
use Test2::Tools::Exception;

subtest "Event: new event" => sub {
    my $event = Hydra::Event->new_event("build_started", "19");
    is($event->{'payload'}, "19");
    is($event->{'channel_name'}, "build_started");
    is($event->{'event'}->{'build_id'}, 19);
};

subtest "Payload type: build_started" => sub {
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

subtest "Payload type: step_finished" => sub {
    like(
        dies { Hydra::Event::parse_payload("step_finished", "") },
        qr/three arguments/,
        "empty payload"
    );
    like(
        dies { Hydra::Event::parse_payload("step_finished", "abc123") },
        qr/three arguments/,
        "one argument"
    );
    like(
        dies { Hydra::Event::parse_payload("step_finished", "abc123\tabc123") },
        qr/three arguments/,
        "two arguments"
    );
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

subtest "Payload type: build_finished" => sub {
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


subtest "Payload type: bogus" => sub {
    like(
        dies { Hydra::Event::parse_payload("bogus", "") },
        qr/Invalid channel name/,
        "bogus channel"
    );
};

done_testing;
