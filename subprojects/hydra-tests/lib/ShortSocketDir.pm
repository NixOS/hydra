use strict;
use warnings;

package ShortSocketDir;

use Exporter 'import';
use File::Temp ();

our @EXPORT_OK = qw(short_socket_dir);

# Unix domain socket paths have a hard limit: sockaddr_un.sun_path is 108
# bytes on Linux, and binding anything longer fails with
# `path must be shorter than SUN_LEN`. Our test temp directories live in
# TMPDIR, which is not necessarily short: `nix develop` wraps the shell in a
# temp directory of its own, and yath nests a per-run directory inside that,
# so by the time a test creates a socket we can be well over the limit.
#
# So sockets go into a directory of our own making, directly under /tmp, and
# the rest of a test's files stay in TMPDIR where the harness can clean (or
# keep, when debugging) the whole tree.
#
# Returns a File::Temp directory object, which stringifies to the path. Keep it
# alive for as long as the socket is in use: it removes the directory when it
# goes away, and the socket inside it has to be unlinked before then.

# Shortest (and most predictable) first; this is the list of directories
# Test::PostgreSQL falls back to for the same reason.
my @CANDIDATE_DIRS = ("/tmp", "/var/tmp");

sub _base_dir {
    foreach my $dir (@CANDIDATE_DIRS) {
        next if not -d $dir or not -w $dir;
        return $dir;
    }
    die "No writable directory for sockets, tried: @CANDIDATE_DIRS\n";
}

sub short_socket_dir {
    my ($template) = @_;
    $template //= "hydra-test-XXXXXXXX";
    return File::Temp->newdir(
        CLEANUP => 1,
        DIR => _base_dir(),
        TEMPLATE => $template,
    );
}

1;
