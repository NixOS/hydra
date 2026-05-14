use warnings;
use strict;

package QueueRunnerBuildOne;
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request;
use ProcessGroup;
use QueueRunnerContext;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    runBuild
    runBuilds
);

sub runBuilds {
    my ($ctx, @builds) = @_;
    ref $ctx eq 'HydraTestContext' or die "runBuilds requires a HydraTestContext as first argument\n";
    my @build_ids = map { $_->id } @builds;

    my ($pg, $base_url, $grpc_addr, $qr_daemon) = start_queue_runner($ctx);

    my $bl_daemon = QueueRunnerContext::start_nix_daemon($ctx->{builder});

    $pg->spawn("builder",
        ["hydra-builder", "--gateway-endpoint", "http://$grpc_addr"],
        env => {
            NIX_REMOTE    => $ctx->{builder}{nix_daemon_uri},
            NIX_CONF_DIR  => $ctx->{builder}{nix_conf_dir},
            NIX_STATE_DIR => $ctx->{builder}{nix_state_dir},
            NIX_STORE_DIR => $ctx->{builder}{nix_store_dir},
            RUST_LOG      => "hydra_builder=debug,info",
        },
    );

    my $ua = LWP::UserAgent->new(timeout => 2);
    my $timeout = 60 * scalar(@build_ids);

    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;

        wait_for_url($ua, "$base_url/status")
            or die "Timed out waiting for queue-runner REST server\n";

        wait_for_url($ua, "$base_url/status/machines", sub {
            shift->decoded_content =~ /"hostname"/;
        }) or die "Timed out waiting for builder to register\n";

        for my $bid (@build_ids) {
            $pg->pump_logs;
            my $req = HTTP::Request->new(POST => "$base_url/build_one");
            $req->header('Content-Type' => 'application/json');
            $req->content(encode_json({ buildId => $bid + 0 }));
            my $resp = $ua->request($req);
            die "Failed to submit build $bid: " . $resp->status_line . "\n"
                unless $resp->is_success;
        }

        wait_for_builds($ua, $base_url, $pg, @build_ids);

        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;

    $pg->stop;
    $bl_daemon->kill_kill(grace => 2);
    $qr_daemon->kill_kill(grace => 2);

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
