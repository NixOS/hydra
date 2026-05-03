use warnings;
use strict;

package QueueRunnerContext;
use IO::Socket::IP;
use IPC::Run;
use LWP::UserAgent;
use POSIX qw(dup2);
use Hydra::Config;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    start_queue_runner
    wait_for_url
);

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

# Start a queue runner process using systemd socket activation.
# We bind TCP sockets ourselves (port 0 for OS-assigned ports), then
# pass them to the queue runner via LISTEN_FDS/LISTEN_FDNAMES.
# Returns ($harness, $rest_url, $grpc_addr, \$stdout_buf, \$stderr_buf).
# Caller is responsible for calling $harness->kill_kill when done.
sub start_queue_runner {
    my ($ctx, %opts) = @_;
    ref $ctx eq 'HydraTestContext' or die "start_queue_runner requires a HydraTestContext\n";

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

    # Bind TCP sockets for both servers (port 0 = OS picks a free port).
    my $rest_sock = IO::Socket::IP->new(
        LocalAddr => '::',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        V6Only    => 0,
    ) or die "Cannot bind REST socket: $!\n";

    my $grpc_sock = IO::Socket::IP->new(
        LocalAddr => '::',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        V6Only    => 0,
    ) or die "Cannot bind gRPC socket: $!\n";

    my $rest_port = $rest_sock->sockport;
    my $grpc_port = $grpc_sock->sockport;

    # The systemd socket activation protocol passes fds starting at 3.
    # We need to place our sockets at fd 3 and fd 4 in the child process.
    # IPC::Run's init callback runs in the child after fork.
    my $rest_fd = fileno($rest_sock);
    my $grpc_fd = fileno($grpc_sock);

    my ($qr_in, $qr_out, $qr_err) = ("", "", "");
    my $qr_harness;
    {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        local $ENV{RUST_LOG} = $opts{rust_log} // "error";
        local $ENV{NO_COLOR} = "1";
        local $ENV{LISTEN_FDS} = "2";
        local $ENV{LISTEN_FDNAMES} = "rest:grpc";
        # Don't set LISTEN_PID — listenfd skips the PID check when it's unset.
        delete $ENV{LISTEN_PID};
        $qr_harness = IPC::Run::start(
            ["hydra-queue-runner",
                "--config-path", $config_file,
                "--rest-bind", "-",
                "--grpc-bind", "-",
                "--disable-queue-monitor-loop",
            ],
            \$qr_in, \$qr_out, \$qr_err,
            init => sub {
                # In the child: place sockets at fd 3 and 4.
                POSIX::dup2($rest_fd, 3) or die "dup2 rest to fd 3: $!";
                POSIX::dup2($grpc_fd, 4) or die "dup2 grpc to fd 4: $!";
                # Close originals if they aren't already 3 or 4.
                POSIX::close($rest_fd) if $rest_fd != 3 && $rest_fd != 4;
                POSIX::close($grpc_fd) if $grpc_fd != 3 && $grpc_fd != 4;
            },
        );
    }

    # Close our copies of the sockets (child has its own).
    close($rest_sock);
    close($grpc_sock);

    my $rest_url = "http://[::1]:$rest_port";
    my $grpc_addr = "[::1]:$grpc_port";

    return ($qr_harness, $rest_url, $grpc_addr, \$qr_out, \$qr_err);
}

1;
