use warnings;
use strict;

package QueueRunnerContext;
use File::Path qw(make_path);
use IO::Socket::IP;
use IPC::Run;
use LWP::UserAgent;
use Hydra::Config;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    get_random_port
    start_queue_runner
    wait_for_url
);

sub get_random_port {
    my ($min, $max) = @_;
    while (1) {
        my $port = $min + int(rand($max - $min + 1));
        my $sock = IO::Socket::IP->new(
            LocalAddr => '::',
            LocalPort => $port,
            Proto     => 'tcp',
            ReuseAddr => 0,
        );
        if ($sock) {
            close($sock);
            return $port;
        }
    }
}

sub wait_for_url {
    my ($ua, $url, $check) = @_;
    for my $i (1..30) {
        my $resp = $ua->get($url);
        if ($resp->is_success) {
            return 1 if !$check || $check->($resp);
        }
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# Start a nix daemon for the given store config.
# Returns the daemon harness.  Caller must kill_kill it when done.
sub start_nix_daemon {
    my ($store) = @_;
    make_path($store->{nix_state_dir});

    my ($in, $out, $err) = ("", "", "");
    my $harness;
    {
        local $ENV{NIX_REMOTE} = $store->{nix_store_uri};
        local $ENV{NIX_STORE_DIR} = $store->{nix_store_dir};
        local $ENV{NIX_STATE_DIR} = $store->{nix_state_dir};
        local $ENV{NIX_CONF_DIR} = $store->{nix_conf_dir};
        local $ENV{NIX_DAEMON_SOCKET_PATH} = $store->{nix_daemon_socket_path};
        local $ENV{NIX_CONFIG} = "trusted-users = *";
        $harness = IPC::Run::start(
            ["nix-daemon"],
            \$in, \$out, \$err,
        );
    }
    my $socket = $store->{nix_daemon_socket_path};
    for (1..50) {
        last if -S $socket;
        select(undef, undef, undef, 0.1);
    }
    -S $socket or die "nix-daemon did not start: $socket\n";
    return $harness;
}

# Start a queue runner process.
# Returns ($harness, $http_url, $grpc_port, \$stdout_buf, \$stderr_buf, $daemon_harness).
# Caller is responsible for calling $harness->kill_kill when done.
sub start_queue_runner {
    my ($ctx, %opts) = @_;
    ref $ctx eq 'HydraTestContext' or die "start_queue_runner requires a HydraTestContext\n";

    # Start a nix daemon for the queue runner to use.
    my $daemon_harness = start_nix_daemon($ctx->{central});

    my $grpc_port = get_random_port(5000, 9999);
    my $http_port = get_random_port(10000, 19999);

    my $config_dir = $ENV{T2_HARNESS_TEMP_DIR}
        // $ctx->{central}{hydra_data};
    my $config_file = "$config_dir/qr-config.toml";

    # Read store settings from the Hydra config file.
    my $hydra_config_file = $ctx->{central}{hydra_config_file};
    my $hydra_config = ($hydra_config_file && -f $hydra_config_file)
        ? Hydra::Config::loadConfig($hydra_config_file) : {};
    my $dest_store_uri = $hydra_config->{store_uri} // "";
    my $use_substitutes = $hydra_config->{'use-substitutes'} // "";

    # Write the TOML config for the queue runner.
    {
        my $db_url = $ctx->{central}{hydra_database_url};
        open(my $fh, '>', $config_file) or die "Cannot write $config_file: $!\n";
        print $fh "dbUrl = \"$db_url\"\n";
        print $fh "hydraDataDir = \"$config_dir/data\"\n";
        print $fh "remoteStoreAddr = [\"$dest_store_uri\"]\n" if $dest_store_uri ne "";
        print $fh "useSubstitutes = true\n" if $use_substitutes eq "1";
        close($fh);
    }

    my ($qr_in, $qr_out, $qr_err) = ("", "", "");

    # Start the queue runner, connecting to the nix daemon via unix://.
    my $qr_harness;
    {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        local $ENV{NIX_REMOTE} = $ctx->{central}{nix_daemon_uri};
        local $ENV{RUST_LOG} = $opts{rust_log} // "error";
        local $ENV{NO_COLOR} = "1";
        $qr_harness = IPC::Run::start(
            ["hydra-queue-runner",
                "--config-path", $config_file,
                "--rest-bind", "[::]:$http_port",
                "--grpc-bind", "[::]:$grpc_port",
                "--disable-queue-monitor-loop",
            ],
            \$qr_in, \$qr_out, \$qr_err,
        );
    }

    my $base_url = "http://[::1]:$http_port";

    return ($qr_harness, $base_url, $grpc_port, \$qr_out, \$qr_err, $daemon_harness);
}

1;
