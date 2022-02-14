use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Model::DB;

use Hydra::PostgresListener;
use Test2::V0;

my $db  = Hydra::Model::DB->new;
my $dbh = $db->storage->dbh;

my $listener = Hydra::PostgresListener->new($dbh);

$listener->subscribe("foo");
$listener->subscribe("bar");

is(undef, $listener->block_for_messages(0)->(), "There is no message");
is(undef, $listener->block_for_messages(0)->(), "There is no message");
is(undef, $listener->block_for_messages(0)->(), "There is no message");

$dbh->do("notify foo, ?", undef, "hi");
my $event = $listener->block_for_messages(0)->();
is($event->{'channel'}, "foo", "The channel matches");
isnt($event->{'pid'}, undef, "The pid is set");
is($event->{'payload'}, "hi", "The payload matches");

is(undef, $listener->block_for_messages(0)->(), "There is no message");

like(
    dies {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        $listener->block_for_messages->();
        alarm 0;
    },
    qr/timeout/,
    "An unspecified block should block forever"
);

like(
    dies {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        $listener->block_for_messages(2)->();
        alarm 0;
    },
    qr/timeout/,
    "A 2-second block goes longer than 1 second"
);

ok(
    lives {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 2;
        is(undef, $listener->block_for_messages(1)->(), "A one second block returns undef data after timeout");
        alarm 0;
    },
    "A 1-second block expires within 2 seconds"
);

subtest "with wacky channel names" => sub {
    my $channel        = "foo! very weird channel names...; select * from t where 1 = 1";
    my $escapedChannel = $dbh->quote_identifier($channel);

    $listener->subscribe($channel);

    is(undef, $listener->block_for_messages(0)->(), "There is no message");

    $dbh->do("notify $escapedChannel, ?", undef, "hi");
    my $event = $listener->block_for_messages(0)->();
    is($event->{'channel'}, $channel, "The channel matches");
    isnt($event->{'pid'}, undef, "The pid is set");
    is($event->{'payload'}, "hi", "The payload matches");
};

done_testing;
