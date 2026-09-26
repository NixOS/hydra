#!/usr/bin/env perl

# We already have a lot of code for automating kanidm for the tests, in KanidmContext.pm.
# So just lean on that as much as we can.

use strict;
use warnings;

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use lib abs_path(dirname(__FILE__) . '/../subprojects/hydra-tests/lib');

use IO::Socket::INET;
use IPC::Run3;
use KanidmContext;
use IO::File;

$| = 1;

mkdir ".hydra-data/kanidm";
my $kanidm_dir = abs_path(".hydra-data/kanidm");

# If foreman was killed hard enough to skip our cleanup (e.g. SIGKILL), an
# orphaned kanidm may still be holding the port. Take it down first, otherwise
# starting a fresh daemon would fail on the address already being in use and
# take the whole foreman stack down with it.
kill_orphaned_kanidm($kanidm_dir);

my $ctx = KanidmContext->new(
    kanidm_dir => $kanidm_dir,
    port => 64448,
);

# Install the handlers before start() so a signal during startup still stops
# the daemon: there is no log-tailing loop around yet to observe $running.
my $running = 1;
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub {
    print "\nShutting down kanidm...\n";
    $running = 0;
    $ctx->kill() if defined $ctx;
};

$ctx->start();
print "Kanidm running at ${\ $ctx->url() } with admin password ${\ $ctx->admin_password }\n";

open my $logfh, '<', $ctx->logfile or die "Cannot open logfile: $!";

$ctx->allow_passwords();
drain_log();
$ctx->create_group('hydra_users');
drain_log();
$ctx->create_group('hydra_admins');
drain_log();
$ctx->create_user(
    'andy',
    groups => ['hydra_users', 'hydra_admins'],
    # Annoyingly password quality checks in kanidm cannot be disabled.
    password => 'kanidm credential',
);
drain_log();
$ctx->create_user(
    'bert',
    groups => ['hydra_users'],
    password => 'kanidm credential',
);
drain_log();
$ctx->create_oauth2_client(
    name => 'hydra',
    redirect_uris => ['http://localhost:63333/oidc-callback/kanidm'],
    scopes => { hydra_users => ['openid', 'email', 'profile']},
    claims => {
        hydra_roles => {
            hydra_admins => ['admin'],
            hydra_users => ['restart_jobs', 'bump_to_front', 'cancel_build'],
        }
    }
);
drain_log();
IO::File->new('.hydra-data/kanidm/hydra_client_secret', 'w')->print($ctx->get_oauth2_secret('hydra'));

while ($running) {
    drain_log();
    $ctx->assert_running();
    sleep 0.2;
}

drain_log();
$ctx->kill();
print "Kanidm stopped.\n";

sub drain_log {
    while (my $line = <$logfh>) {
        print $line;
    }

    # At EOF, clear the EOF condition so we can read data appended to the file
    seek($logfh, 0, 1);
}

sub kill_orphaned_kanidm {
    my ($dir) = @_;

    return unless port_in_use(64448);

    my $out = '';
    my $err = '';
    eval {
        run3(['pgrep', '-f', 'kanidmd.*' . quotemeta("$dir/kanidm.toml")], \undef, \$out, \$err);
        1;
    } or return;

    my @pids = grep { /^\d+$/ } split /\n/, $out;
    return unless @pids;

    print "Killing orphaned kanidm (pids @pids) still holding port 64448\n";
    kill 'TERM', @pids;

    # Wait (bounded) for the port to be released so the new daemon can bind.
    for (1 .. 10) {
        last unless port_in_use(64448);
        sleep 1;
    }
}

sub port_in_use {
    my ($port) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
        Timeout => 2,
    );
    return 0 unless $sock;
    close $sock;
    return 1;
}
