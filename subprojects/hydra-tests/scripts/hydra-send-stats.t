use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use QueueRunnerContext;
use LWP::UserAgent;
use File::Slurper qw(write_text);

my %ctx = test_init();

require Hydra::Schema;

use Test2::V0;

my $db = $ctx{context}->db();

subtest "without queue_runner_endpoint" => sub {
    my ($res, $stdout, $stderr) = $ctx{context}->capture_cmd(60, ("hydra-send-stats", "--once"));
    is($stdout, "", "stdout should be empty");
    like($stderr, qr/queue_runner_endpoint not configured/, "warns about missing endpoint");
    is($res, 0, "exits zero (error is non-fatal)");
};

subtest "with queue_runner_endpoint" => sub {
    my ($pg, $base_url) = start_queue_runner($ctx{context});

    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 30;

        # Wait for the REST server to come up.
        my $ua = LWP::UserAgent->new(timeout => 2);
        wait_for_url($ua, "$base_url/status")
            or die "Timed out waiting for queue-runner REST server\n";

        # Write a hydra.conf pointing at our queue runner.
        my $config_dir = $ENV{T2_HARNESS_TEMP_DIR}
            // $ctx{context}->{central}{hydra_data};
        my $hydra_conf = "$config_dir/hydra-send-stats-test.conf";
        write_text($hydra_conf, "queue_runner_endpoint = $base_url\n");

        # Run hydra-send-stats with the test config.
        local $ctx{context}->{central_env}{HYDRA_CONFIG} = $hydra_conf;
        my ($res, $stdout, $stderr) = $ctx{context}->capture_cmd(
            60, ("hydra-send-stats", "--once"),
        );
        is($stdout, "", "stdout should be empty");
        is($stderr, "", "stderr should be empty");
        is($res, 0, "exits zero");

        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;

    $pg->stop;

    die "with queue_runner_endpoint failed: $err" if !$ok && $err;
};

done_testing;
