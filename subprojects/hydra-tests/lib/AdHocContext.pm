use warnings;
use strict;

package AdHocContext;

# Spin up the full stack required for builds submitted directly through
# hydra-ad-hoc: an upstream nix-daemon (so hydra-ad-hoc has
# something to proxy reads / .drv uploads to), hydra-ad-hoc itself,
# and a queue-runner + builder pair (shared with QueueRunnerBuildOne
# via QueueRunnerContext) that picks up the rows it inserts.
#
# Returns an object whose DESTROY tears everything down. Use
# `daemon_socket` to point a `nix-build` / `nix-store` invocation at
# hydra-ad-hoc, and `nix_remote_url` for the same over `NIX_REMOTE`.

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
        or die "AdHocContext requires a HydraTestContext\n";

    my $tmpdir = $ctx->{tmpdir};
    my $upstream_sock = "$tmpdir/upstream-nix-daemon.sock";
    my $daemon_sock = "$tmpdir/ad-hoc.sock";

    # The upstream nix-daemon and hydra-ad-hoc have to be up before the
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
    $self->_spawn_ad_hoc;

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

sub _spawn_ad_hoc {
    my ($self) = @_;
    my $ctx = $self->{ctx};

    # The database URL comes from HYDRA_DATABASE_URL in central_env,
    # which overrides whatever the config file says.
    my $config = "$ctx->{tmpdir}/ad-hoc.toml";
    open(my $fh, '>', $config) or die "cannot write $config: $!\n";
    print $fh "upstreamSocket = \"$self->{upstream_sock}\"\n";
    print $fh "storeDir = \"$ctx->{central}{nix_store_dir}\"\n";
    close $fh;

    $self->{pre_pg}->spawn(
        "hydra-ad-hoc",
        [
            "hydra-ad-hoc",
            "--socket",      $self->{daemon_sock},
            "--config-path", $config,
        ],
        env => { RUST_LOG => "hydra_ad_hoc=debug,info" },
    );
    wait_for_socket($self->{daemon_sock})
        or die "hydra-ad-hoc socket did not appear at $self->{daemon_sock}\n";
}

sub daemon_socket { return $_[0]->{daemon_sock}; }

# `unix://` ignores NIX_STORE_DIR for its logical store path; the only
# way to make the client agree with the daemon is to pass
# `?store=<dir>` as a URL parameter. `/` and `:` stay literal so the
# URL is human-readable; anything else gets percent-encoded.
#
# The central store is a chroot, so `root=` has to come along too:
# without it the client resolves the store dir to itself on disk and
# cannot read the .drv back after the build to print its outputs.
sub nix_remote_url {
    my ($self) = @_;
    my $central = $self->{ctx}{central};
    my $esc = "^A-Za-z0-9\\-_.~/:";
    return
        "unix://" . uri_escape($self->{daemon_sock}, $esc)
      . "?root="  . uri_escape($central->{root},          $esc)
      . "&store=" . uri_escape($central->{nix_store_dir}, $esc);
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
# first, then hydra-ad-hoc and the upstream daemon they talked to.
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
