use warnings;
use strict;

package QueueRunnerBuildOne;
use IO::Socket::IP;
use IPC::Run;
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request;
use Hydra::Config;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    runBuild
    runBuilds
);

sub _get_random_port {
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

sub _wait_for {
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

sub _flush_stream {
    my ($label, $stream, $buf_ref, $final) = @_;
    return if $$buf_ref eq "";
    utf8::decode($$buf_ref) or warn "Invalid unicode in $label $stream.";
    # Print each complete line with a label prefix. Leave any trailing
    # partial line in the buffer so it can be flushed together with the
    # rest of its line on a subsequent call.
    while ($$buf_ref =~ s/^([^\n]*)\n//) {
        print STDERR "[$label $stream] $1\n";
    }
    if ($final && $$buf_ref ne "") {
        print STDERR "[$label $stream] $$buf_ref\n";
        $$buf_ref = "";
    }
}

sub _flush_harness {
    my ($label, $out_ref, $err_ref, $final) = @_;
    _flush_stream($label, "stdout", $out_ref, $final);
    _flush_stream($label, "stderr", $err_ref, $final);
}

sub runBuilds {
    my ($ctx, @builds) = @_;
    ref $ctx eq 'HydraTestContext' or die "runBuilds requires a HydraTestContext as first argument\n";
    my @build_ids = map { $_->id } @builds;

    my $grpc_port = _get_random_port(5000, 9999);
    my $http_port = _get_random_port(10000, 19999);

    my $config_dir = $ENV{T2_HARNESS_TEMP_DIR}
        // $ctx->{central}{hydra_data};
    my $config_file = "$config_dir/config.toml";

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
    my ($bl_in, $bl_out, $bl_err) = ("", "", "");

    # Start the queue runner with central env applied.
    my $qr_harness;
    {
        local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
        local $ENV{RUST_LOG} = "queue_runner=debug,info";
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
    my $ua = LWP::UserAgent->new(timeout => 2);
    my $bl_harness;

    my $timeout = 60 * scalar(@build_ids);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        # Wait for the REST server to become available.
        _wait_for($ua, "$base_url/status")
            or die "Timed out waiting for queue-runner REST server\n";

        # Start the builder with its own store settings.
        {
            local $ENV{NIX_REMOTE} = $ctx->{builder}{nix_store_uri};
            local $ENV{NIX_CONF_DIR} = $ctx->{builder}{nix_conf_dir};
            local $ENV{NIX_STATE_DIR} = $ctx->{builder}{nix_state_dir};
            # TODO: hydra-builder reads NIX_STORE_DIR to report its
            # store dir to the queue runner; should use the store URI instead.
            local $ENV{NIX_STORE_DIR} = $ctx->{builder}{nix_store_dir};
            local $ENV{RUST_LOG} = "hydra_builder=debug,info";
            local $ENV{NO_COLOR} = "1";
            $bl_harness = IPC::Run::start(
                ["hydra-builder",
                    "--gateway-endpoint", "http://[::1]:$grpc_port",
                ],
                \$bl_in, \$bl_out, \$bl_err,
            );
        }

        # Wait for the builder to register as a machine.
        _wait_for($ua, "$base_url/status/machines", sub {
            shift->decoded_content =~ /"hostname"/;
        }) or die "Timed out waiting for builder to register\n";

        # Submit all builds. Returns 200 even if a build is already finished.
        for my $bid (@build_ids) {
            my $req = HTTP::Request->new(POST => "$base_url/build_one");
            $req->header('Content-Type' => 'application/json');
            $req->content(encode_json({ buildId => $bid + 0 }));
            my $resp = $ua->request($req);
            die "Failed to submit build $bid: " . $resp->status_line . "\n"
                unless $resp->is_success;
        }

        # Poll until every build is no longer active.
        while (1) {
            # If the builder crashed, fail fast instead of waiting for the
            # queue-runner to time out the orphaned builds.
            $qr_harness->pump_nb;
            $bl_harness->pump_nb;
            # Flush accumulated output so logs are visible while waiting.
            _flush_harness("Queue runner", \$qr_out, \$qr_err);
            _flush_harness("Builder", \$bl_out, \$bl_err);
            if (!$bl_harness->pumpable) {
                $bl_harness->finish;
                my $rc = $bl_harness->result;
                print STDERR "builder exited unexpectedly (exit code $rc)\n";
                die "builder exited unexpectedly\n";
            }

            my $all_done = 1;
            for my $bid (@build_ids) {
                my $resp = $ua->get("$base_url/status/build/$bid/active");
                if ($resp->decoded_content =~ /true/) {
                    $all_done = 0;
                    last;
                }
            }
            last if $all_done;
            sleep 2;
        }

        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;

    # Always clean up child processes, then flush any trailing stderr
    # that arrived after the last poll iteration.
    if ($bl_harness) {
        $bl_harness->kill_kill;
        _flush_harness("Builder", \$bl_out, \$bl_err, 1);
    }
    $qr_harness->kill_kill;
    _flush_harness("Queue runner", \$qr_out, \$qr_err, 1);

    if (!$ok) {
        print STDERR "runBuilds failed: $err" if $err;
        return 0;
    }
    return 1;
}

sub runBuild {
    my ($ctx, $build) = @_;
    return runBuilds($ctx, $build);
}

1;
