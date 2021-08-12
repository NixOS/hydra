use strict;
use Hydra::Event;
use Hydra::Event::BuildFinished;

use Test2::V0;
use Test2::Tools::Exception;

subtest "Event: new event" => sub {
    my $event = Hydra::Event->new_event("build_started", "19");
    is($event->{'payload'}, "19");
    is($event->{'channel_name'}, "build_started");
    is($event->{'event'}->{'build_id'}, 19);
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
