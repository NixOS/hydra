use strict;
use warnings;
use Setup;
use Test2::V0;

use Hydra::Helper::BuildDiff;

my $ctx = test_context();

subtest "response" => sub {
    my $ret = buildDiff([], []);
    is($ret, {
        stillSucceed => [],
        stillFail => [],
        nowSucceed => [],
        nowFail => [],
        new => [],
        removed => [],
        unfinished => [],
        aborted => [],
        failed => [],
    });
};

is(1, 1);

done_testing;
