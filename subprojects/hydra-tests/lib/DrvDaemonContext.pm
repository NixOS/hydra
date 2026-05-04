use warnings;
use strict;

package DrvDaemonContext;

# Spin up the full stack required for builds submitted directly through
# hydra-drv-daemon: an upstream nix-daemon (so the drv-daemon has
# something to proxy reads / .drv uploads to), the drv-daemon itself,
# and a queue-runner + builder pair (shared with QueueRunnerBuildOne
# via QueueRunnerContext) that picks up the rows it inserts.
#
# Returns an object whose DESTROY tears everything down. Use
# `daemon_socket` to point a `nix-build` / `nix-store` invocation at
# the drv-daemon, and `nix_remote_url` for the same over `NIX_REMOTE`.

use IPC::Run;
use LWP::UserAgent;
use URI::Escape qw(uri_escape);
use QueueRunnerContext qw(
    start_queue_runner
    start_builder
    wait_for_socket
    wait_for_url
);

our @ISA = qw(Exporter);
our @EXPORT = qw();

sub _flush_stream {
    my ($label, $stream, $buf_ref, $final) = @_;
    return if $$buf_ref eq "";
    utf8::decode($$buf_ref) or warn "Invalid unicode in $label $stream.";
    while ($$buf_ref =~ s/^([^\n]*)\n//) {
        print STDERR "[$label $stream] $1\n";
    }
    if ($final && $$buf_ref ne "") {
        print STDERR "[$label $stream] $$buf_ref\n";
        $$buf_ref = "";
    }
}

sub _flush_proc {
    my ($p, $final) = @_;
    _flush_stream($p->{label}, "stdout", $p->{out}, $final);
    _flush_stream($p->{label}, "stderr", $p->{err}, $final);
}

sub new {
    my ($class, $ctx) = @_;
    ref $ctx eq 'HydraTestContext'
        or die "DrvDaemonContext requires a HydraTestContext\n";

    my $tmpdir = $ctx->{tmpdir};
    my $upstream_sock = "$tmpdir/upstream-nix-daemon.sock";
    my $daemon_sock = "$tmpdir/drv-daemon.sock";

    my $self = bless {
        ctx           => $ctx,
        upstream_sock => $upstream_sock,
        daemon_sock   => $daemon_sock,
        procs         => {},
    }, $class;

    $self->_spawn_upstream;
    $self->_spawn_drv_daemon;

    my ($qr_harness, $base_url, $grpc_port, $qr_out, $qr_err) =
        start_queue_runner($ctx,
            queue_monitor_loop => 1,
            rust_log           => "queue_runner=debug,info",
        );
    $self->{procs}{queue_runner} = {
        label   => "Queue runner",
        harness => $qr_harness,
        out     => $qr_out,
        err     => $qr_err,
    };
    $self->{base_url}  = $base_url;
    $self->{grpc_port} = $grpc_port;
    $self->{ua}        = LWP::UserAgent->new(timeout => 2);

    my ($bl_harness, $bl_out, $bl_err) =
        start_builder($ctx, $grpc_port, rust_log => "hydra_builder=debug,info");
    $self->{procs}{builder} = {
        label   => "Builder",
        harness => $bl_harness,
        out     => $bl_out,
        err     => $bl_err,
    };

    wait_for_url($self->{ua}, "$base_url/status/machines", sub {
        shift->decoded_content =~ /"hostname"/;
    }) or die "Timed out waiting for builder to register\n";

    return $self;
}

sub _spawn {
    my ($self, $key, $label, $cmd, %opts) = @_;
    my %env = %{ $self->{ctx}{central_env} };
    if ($opts{env}) {
        $env{$_} = $opts{env}{$_} for keys %{$opts{env}};
    }
    my ($in, $out, $err) = ("", "", "");
    my $harness;
    {
        local @ENV{keys %env} = values %env;
        local $ENV{NO_COLOR} = "1";
        $harness = IPC::Run::start($cmd, \$in, \$out, \$err);
    }
    $self->{procs}{$key} = {
        label   => $label,
        harness => $harness,
        out     => \$out,
        err     => \$err,
    };
}

sub _spawn_upstream {
    my ($self) = @_;
    # socat keeps the listener alive across connections by forking a
    # fresh `nix-daemon --stdio` per accept. The legacy command honours
    # NIX_STORE_DIR / NIX_STATE_DIR from central_env, which already
    # points at the test's on-disk store.
    $self->_spawn(
        upstream => "Upstream nix daemon",
        [
            "socat",
            "UNIX-LISTEN:$self->{upstream_sock},fork,reuseaddr,unlink-early",
            "EXEC:nix-daemon --stdio,nofork",
        ],
    );
    wait_for_socket($self->{upstream_sock})
        or die "upstream nix-daemon socket did not appear at $self->{upstream_sock}\n";
}

sub _spawn_drv_daemon {
    my ($self) = @_;
    my $ctx = $self->{ctx};
    my $db_url = $ctx->{central}{hydra_database_url};
    my $store_dir = $ctx->{central}{nix_store_dir};

    $self->_spawn(
        drv_daemon => "drv-daemon",
        [
            "hydra-drv-daemon",
            "--socket",          $self->{daemon_sock},
            "--upstream-socket", $self->{upstream_sock},
            "--db-url",          $db_url,
            "--store-dir",       $store_dir,
        ],
        env => { RUST_LOG => "hydra_drv_daemon=debug,info" },
    );
    wait_for_socket($self->{daemon_sock})
        or die "hydra-drv-daemon socket did not appear at $self->{daemon_sock}\n";
}

sub daemon_socket { return $_[0]->{daemon_sock}; }

# `unix://` ignores NIX_STORE_DIR for its logical store path; the only
# way to make the client agree with the daemon is to pass
# `?store=<dir>` as a URL parameter. `/` and `:` stay literal so the
# URL is human-readable; anything else gets percent-encoded.
sub nix_remote_url {
    my ($self) = @_;
    my $store_dir = $self->{ctx}{central}{nix_store_dir};
    return
        "unix://" . uri_escape($self->{daemon_sock}, "^A-Za-z0-9\\-_.~/:")
      . "?store=" . uri_escape($store_dir,           "^A-Za-z0-9\\-_.~/:");
}

sub pump_logs {
    my ($self) = @_;
    for my $key (keys %{$self->{procs}}) {
        my $p = $self->{procs}{$key};
        eval { $p->{harness}->pump_nb };
        _flush_proc($p);
    }
}

# Block until the queue runner reports no in-flight builds for any of
# @build_ids. Bails out if the builder dies.
sub wait_for_builds_to_finish {
    my ($self, @build_ids) = @_;
    my $ua = $self->{ua};
    my $base_url = $self->{base_url};

    my $timeout = 60 * scalar(@build_ids);
    $timeout = 60 if $timeout < 60;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        $self->pump_logs;
        my $bl = $self->{procs}{builder}{harness};
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

sub run_cmd {
    my ($self, $timeout, @cmd) = @_;
    my %env = (
        %{ $self->{ctx}{central_env} },
        NIX_REMOTE => $self->nix_remote_url,
    );

    my ($cmd_in, $cmd_out, $cmd_err) = ("", "", "");
    my $h;
    {
        local @ENV{keys %env} = values %env;
        local $ENV{NO_COLOR} = "1";
        $h = IPC::Run::start(\@cmd, \$cmd_in, \$cmd_out, \$cmd_err);
    }

    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        eval { $h->pump_nb };
        my $err = $@;
        # Flush daemon-side logs so yath's event-timeout doesn't trigger
        # while we wait for the client to come back.
        $self->pump_logs;
        if ($err) {
            return (1, $cmd_out, $cmd_err . "\n[run_cmd: pump_nb error: $err]");
        }
        if (!$h->pumpable) {
            $h->finish;
            my $rc = scalar $h->result;
            unless (defined $rc) {
                return (
                    1, $cmd_out,
                    $cmd_err . "\n[run_cmd: IPC::Run::result returned undef; child likely crashed without a clean exit]",
                );
            }
            return ($rc, $cmd_out, $cmd_err);
        }
        select(undef, undef, undef, 0.5);
    }
    eval { $h->kill_kill };
    return (1, $cmd_out, $cmd_err . "\n[run_cmd: timed out after ${timeout}s]");
}

sub stop {
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    for my $key (qw(builder queue_runner drv_daemon upstream)) {
        my $p = $self->{procs}{$key};
        next unless $p;
        eval { $p->{harness}->kill_kill };
        _flush_proc($p, 1);
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->stop;
}

1;
