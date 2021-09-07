use strict;
use warnings;
use Setup;

my %ctx = test_init();

use Hydra::Event;
use Hydra::Task;
require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $taskretries = $db->resultset('TaskRetries');

subtest "get_seconds_to_next_retry" => sub {
    subtest "Without any records in the database" => sub {
        is($taskretries->get_seconds_to_next_retry(), undef, "Without any records our next retry moment is forever away.");
    };

    subtest "With only tasks whose retry timestamps are in the future" => sub {
        $taskretries->create({
            channel => "bogus",
            pluginname => "bogus",
            payload => "bogus",
            attempts => 1,
            retry_at => time() + 100,
        });
        is($taskretries->get_seconds_to_next_retry(), within(100, 2), "We should retry in roughly 100 seconds");
    };

    subtest "With tasks whose retry timestamp are in the past" => sub {
        $taskretries->create({
            channel => "bogus",
            pluginname => "bogus",
            payload => "bogus",
            attempts => 1,
            retry_at => time() - 100,
        });
        is($taskretries->get_seconds_to_next_retry(), 0, "We should retry immediately");
    }
};

subtest "save_task" => sub {
    my $event = Hydra::Event->new_event("build_started", "1");
    my $task = Hydra::Task->new(
        $event,
        "FooPluginName",
    );

    my $retry = $taskretries->save_task($task);

    is($retry->channel, "build_started", "Channel name should match");
    is($retry->pluginname, "FooPluginName", "Plugin name should match");
    is($retry->payload, "1", "Payload should match");
    is($retry->attempts, 1, "We've had one attempt");
    is($retry->retry_at, within(time() + 1, 2), "The retry at should be approximately one second away");
};

done_testing;
