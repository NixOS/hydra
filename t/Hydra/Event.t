use strict;
use warnings;
use Hydra::Event;

use Test2::V0;
use Test2::Tools::Exception;

subtest "Event: new event" => sub {
    my $event = Hydra::Event->new_event("build_started", "19");
    is($event->{'payload'}, "19");
    is($event->{'channel_name'}, "build_started");
    is($event->{'event'}->{'build_id'}, 19);
};

subtest "Payload type: bogus" => sub {
    like(
        dies { Hydra::Event::parse_payload("bogus", "") },
        qr/Invalid channel name/,
        "bogus channel"
    );
};

done_testing;
