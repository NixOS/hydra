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
use ProcessGroup;
use QueueRunnerContext qw(
    start_queue_runner
    start_builder
    wait_for_builds
    wait_for_socket
    wait_for_url
);

our @ISA = qw(Exporter);
our @EXPORT = qw();

sub new {
    my ($class, $ctx) = @_;
    ref $ctx eq 'HydraTestContext'
        or die "DrvDaemonContext requires a HydraTestContext\n";

    my $tmpdir = $ctx->{tmpdir};
    my $upstream_sock = "$tmpdir/upstream-nix-daemon.sock";
    my $daemon_sock = "$tmpdir/drv-daemon.sock";

    # The upstream nix-daemon and the drv-daemon have to be up before the
    # queue runner, so they get their own group; start_queue_runner builds
    # the one that holds the queue runner and builder.
    my $pre_pg = ProcessGroup->new(env => $ctx->{central_env});

    my $self = bless {
        ctx           => $ctx,
        upstream_sock => $upstream_sock,
        daemon_sock   => $daemon_sock,
        pre_pg        => $pre_pg,
    }, $class;

    $self->_spawn_upstream;
    $self->_spawn_drv_daemon;

    my ($pg, $base_url, $grpc_addr) =
        start_queue_runner($ctx, queue_monitor_loop => 1);
    $self->{pg}        = $pg;
    $self->{base_url}  = $base_url;
    $self->{grpc_addr} = $grpc_addr;
    $self->{ua}        = LWP::UserAgent->new(timeout => 2);

    start_builder($ctx, $grpc_addr, $pg);

    wait_for_url($self->{ua}, "$base_url/status/machines", sub {
        shift->decoded_content =~ /"hostname"/;
    }) or die "Timed out waiting for builder to register\n";

    return $self;
}

sub _spawn_upstream {
    my ($self) = @_;
    # socat keeps the listener alive across connections by forking a
    # fresh `nix-daemon --stdio` per accept. The legacy command honours
    # NIX_STORE_DIR / NIX_STATE_DIR from central_env, which already
    # points at the test's on-disk store.
    $self->{pre_pg}->spawn(
        "upstream nix daemon",
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

    $self->{pre_pg}->spawn(
        "drv-daemon",
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
    $self->{pre_pg}->pump_logs;
    $self->{pg}->pump_logs if $self->{pg};
}

# Block until the queue runner reports no in-flight builds for any of
# @build_ids. Bails out if the builder dies.
sub wait_for_builds_to_finish {
    my ($self, @build_ids) = @_;
    $self->{pre_pg}->pump_logs;
    return wait_for_builds($self->{ua}, $self->{base_url}, $self->{pg}, @build_ids);
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

# Tear down in reverse dependency order: the queue runner and builder
# first, then the drv-daemon and the upstream daemon they talked to.
sub stop {
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    $self->{pg}->stop if $self->{pg};
    $self->{pre_pg}->stop;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop;
}

1;
