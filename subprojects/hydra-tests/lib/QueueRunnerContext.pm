use warnings;
use strict;

package QueueRunnerContext;
use IO::Socket::IP;
use IPC::Run;
use LWP::UserAgent;
use Hydra::Config;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    get_random_port
    start_builder
    start_queue_runner
    wait_for_socket
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

sub wait_for_socket {
    my ($path) = @_;
    for my $i (1..60) {
        return 1 if -S $path;
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# Start a queue runner process.
# Returns ($harness, $http_url, $grpc_port, \$stdout_buf, \$stderr_buf).
# Caller is responsible for calling $harness->kill_kill when done.
#
# Options:
#   rust_log: RUST_LOG value, default "error".
#   queue_monitor_loop: 1 to leave the queue-monitor-loop running so
#     the queue runner picks up new Builds rows on its own (the
#     drv-daemon's ad-hoc flow needs this). Default 0 (disabled), which
#     matches QueueRunnerBuildOne's manual /build_one driver.
sub start_queue_runner {
    my ($ctx, %opts) = @_;
    ref $ctx eq 'HydraTestContext' or die "start_queue_runner requires a HydraTestContext\n";

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

    my @args = (
        "hydra-queue-runner",
        "--config-path", $config_file,
        "--rest-bind", "[::]:$http_port",
        "--grpc-bind", "[::]:$grpc_port",
    );
    push @args, "--disable-queue-monitor-loop" unless $opts{queue_monitor_loop};

    # Start the queue runner with central env applied.
    my $qr_harness;
    {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        local $ENV{RUST_LOG} = $opts{rust_log} // "error";
        local $ENV{NO_COLOR} = "1";
        $qr_harness = IPC::Run::start(\@args, \$qr_in, \$qr_out, \$qr_err);
    }

    my $base_url = "http://[::1]:$http_port";

    return ($qr_harness, $base_url, $grpc_port, \$qr_out, \$qr_err);
}

# Start a hydra-builder against an already-running queue runner.
# Returns ($harness, \$stdout_buf, \$stderr_buf).
sub start_builder {
    my ($ctx, $grpc_port, %opts) = @_;
    ref $ctx eq 'HydraTestContext' or die "start_builder requires a HydraTestContext\n";

    my ($bl_in, $bl_out, $bl_err) = ("", "", "");
    my $bl_harness;
    {
        local $ENV{NIX_REMOTE}    = $ctx->{builder}{nix_store_uri};
        local $ENV{NIX_CONF_DIR}  = $ctx->{builder}{nix_conf_dir};
        local $ENV{NIX_STATE_DIR} = $ctx->{builder}{nix_state_dir};
        # TODO: hydra-builder reads NIX_STORE_DIR to report its store
        # dir to the queue runner; should use the store URI instead.
        local $ENV{NIX_STORE_DIR} = $ctx->{builder}{nix_store_dir};
        local $ENV{RUST_LOG}      = $opts{rust_log} // "error";
        local $ENV{NO_COLOR}      = "1";
        $bl_harness = IPC::Run::start(
            ["hydra-builder", "--gateway-endpoint", "http://[::1]:$grpc_port"],
            \$bl_in, \$bl_out, \$bl_err,
        );
    }
    return ($bl_harness, \$bl_out, \$bl_err);
}

1;
