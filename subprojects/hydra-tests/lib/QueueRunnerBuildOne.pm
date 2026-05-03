use warnings;
use strict;

package QueueRunnerBuildOne;
use IPC::Run;
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request;
use QueueRunnerContext;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    runBuild
    runBuilds
);

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

    my ($qr_harness, $base_url, $grpc_addr, $qr_out_ref, $qr_err_ref) = start_queue_runner($ctx,
        rust_log => "queue_runner=debug,info",
    );

    my ($bl_in, $bl_out, $bl_err) = ("", "", "");
    my $ua = LWP::UserAgent->new(timeout => 2);
    my $bl_harness;

    my $timeout = 60 * scalar(@build_ids);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        # Wait for the REST server to become available.
        wait_for_url($ua, "$base_url/status")
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
                    "--gateway-endpoint", "http://$grpc_addr",
                ],
                \$bl_in, \$bl_out, \$bl_err,
            );
        }

        # Wait for the builder to register as a machine.
        wait_for_url($ua, "$base_url/status/machines", sub {
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
            _flush_harness("Queue runner", $qr_out_ref, $qr_err_ref);
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
    _flush_harness("Queue runner", $qr_out_ref, $qr_err_ref, 1);

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
