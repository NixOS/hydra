use strict;
use warnings;
use Setup;

use Hydra::Math qw(exponential_backoff);

use Test2::V0;

subtest "exponential_backoff" => sub {
    is(exponential_backoff(0), 1);
    is(exponential_backoff(1), 2);
    is(exponential_backoff(2), 4);
    is(exponential_backoff(9), 512);
    is(exponential_backoff(10), 1024);
    is(exponential_backoff(11), 1024, "we're clamped to 1024 seconds");
    is(exponential_backoff(11000), 1024, "we're clamped to 1024 seconds");
};

done_testing;
