#!/usr/bin/env perl

# We already have a lot of code for automating kanidm for the tests, in KanidmContext.pm.
# So just lean on that as much as we can.

use strict;
use warnings;

use lib qw(t/lib);

use Cwd qw(abs_path);
use KanidmContext;
use IO::File;

mkdir ".hydra-data/kanidm";

my $ctx = KanidmContext->new(
    kanidm_dir => abs_path(".hydra-data/kanidm"),
    port => 64448,
);
$ctx->start();
print "Kanidm running at ${\ $ctx->url() } with admin password ${\ $ctx->admin_password }\n";

$ctx->allow_passwords();
$ctx->create_group('hydra_users');
$ctx->create_group('hydra_admins');
$ctx->create_user(
    'andy',
    groups => ['hydra_users', 'hydra_admins'],
    # Annoyingly password quality checks in kanidm cannot be disabled.
    password => 'kanidm credential',
);
$ctx->create_user(
    'bert',
    groups => ['hydra_users'],
    password => 'kanidm credential',
);
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
IO::File->new('.hydra-data/kanidm/hydra_client_secret', 'w')->print($ctx->get_oauth2_secret('hydra'));

my $running = 1;
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub {
    print "\nShutting down kanidm...\n";
    $running = 0;
};

open my $logfh, '<', $ctx->logfile or die "Cannot open logfile: $!";

while ($running) {
    while (my $line = <$logfh>) {
        print $line;
    }
    $ctx->assert_running();

    # At EOF, sleep briefly and try again
    # Clear EOF condition so we can read new data appended to the file
    seek($logfh, 0, 1);
    sleep 1;
}

$ctx->kill();
print "Kanidm stopped.\n";
