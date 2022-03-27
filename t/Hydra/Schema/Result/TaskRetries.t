use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $taskretries = $db->resultset('TaskRetries');

subtest "requeue" => sub {
    my $task = $taskretries->create({
        channel => "bogus",
        pluginname => "bogus",
        payload => "bogus",
        attempts => 1,
        retry_at => time(),
    });

    $task->requeue();
    is($task->attempts, 2, "We should have stored a second retry");
    is($task->retry_at, within(time() + 4, 2), "Delayed two exponential backoff step");

    $task->requeue();
    is($task->attempts, 3, "We should have stored a third retry");
    is($task->retry_at, within(time() + 8, 2), "Delayed a third exponential backoff step");
};

done_testing;
