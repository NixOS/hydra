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

done_testing;
