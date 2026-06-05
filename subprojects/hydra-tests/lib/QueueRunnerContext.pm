use warnings;
use strict;

package QueueRunnerContext;
use IO::Socket::IP;
use IPC::Run;
use LWP::UserAgent;
use POSIX qw(dup2);
use Hydra::Config;
use NixDaemon qw(start_nix_daemon);
use ProcessGroup;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    start_queue_runner
    wait_for_builds
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
# Returns ($process_group, $rest_url, $grpc_addr).
# The ProcessGroup has the nix daemon and queue-runner registered.
# Caller is responsible for calling $pg->stop when done.
sub start_queue_runner {
    my ($ctx, %opts) = @_;
    ref $ctx eq 'HydraTestContext' or die "start_queue_runner requires a HydraTestContext\n";

    my $pg = ProcessGroup->new;

    # Start a nix daemon for the queue runner to use.
    start_nix_daemon($ctx->{central}, $pg, "queue-runner daemon");

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

    # Start the queue runner, connecting to the nix daemon via unix://.
    my $qr_harness;
    {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        local $ENV{NIX_REMOTE} = $ctx->{central}{nix_daemon_uri};
        local $ENV{RUST_LOG} = "hydra_queue_runner=debug,info";
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

    $pg->{procs}{"queue-runner"} = {
        label => "queue-runner", harness => $qr_harness, out => \$qr_out, err => \$qr_err,
    };
    push @{$pg->{order}}, "queue-runner";

    return ($pg, $rest_url, $grpc_addr);
}

# Poll the queue runner REST API until all given build IDs are no longer
# active. Calls $pg->pump_logs each iteration so test output stays visible.
#
# Args: ($ua, $base_url, $process_group, @build_ids)
# Dies on timeout or if the builder process exits unexpectedly.
sub wait_for_builds {
    my ($ua, $base_url, $pg, @build_ids) = @_;
    my $timeout = 60 * scalar(@build_ids);
    $timeout = 60 if $timeout < 60;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        $pg->pump_logs;
        my $bl = $pg->harness("builder");
        if ($bl && !$bl->pumpable) {
            $bl->finish;
            my $rc = $bl->result;
            die "builder exited unexpectedly (exit code $rc)\n";
        }

        my $all_done = 1;
        for my $bid (@build_ids) {
            my $resp = $ua->get("$base_url/status/build/$bid/active");
            if ($resp->decoded_content =~ /true/) {
                $all_done = 0;
                last;
            }
        }
        return 1 if $all_done;
        sleep 2;
    }
    die "timed out waiting for builds to finish\n";
}

1;
