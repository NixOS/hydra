use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use AdHocContext;
use Hydra::Helper::Exec;

# More concurrent ad hoc builds than the daemon has database
# connections. A build can take hours, so the daemon must not hold a
# pool connection while it waits for the queue runner; if it did, the
# pool would fill up after a few in-flight requests and every later
# client would stall, then fail with "pool timed out".
#
# `maxDbConnections = 2` leaves one connection for request handling
# (the build_finished listener holds the other), so three clients at
# once is enough to tell the two behaviours apart.

my $ctx = test_context();
my $jobsdir = $ctx->jobsdir;

my @drvs;
{
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    for my $attr (qw(a b c)) {
        my ($res, $stdout, $stderr) = captureStdoutStderr(60,
            "nix-instantiate", "$jobsdir/ad-hoc/slow.nix", "-A", $attr,
        );
        if ($res) {
            chomp $stderr;
            diag("nix-instantiate $attr failed: $stderr");
            die "nix-instantiate failed\n";
        }
        chomp $stdout;
        $stdout =~ s/!.*$//;
        push @drvs, $stdout;
    }
}
is(scalar(@drvs), 3, "instantiated three distinct derivations");

my $stack = AdHocContext->new($ctx, max_db_connections => 2);

my @results = $stack->run_cmds(300,
    map { [ "nix-store", "--realise", $_ ] } @drvs,
);
$stack->pump_logs;

for my $i (0 .. $#drvs) {
    my ($rc, $out, $err) = @{ $results[$i] };
    if ($rc) {
        chomp $err;
        diag("nix-store --realise $drvs[$i] failed: $err");
    }
    is($rc + 0, 0, "concurrent ad hoc build $i succeeded");
}

my $db = $ctx->db();
my $finished = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc', 'me.finished' => 1, 'me.buildstatus' => 0 },
    { join => 'jobset' },
)->count;
is($finished, 3, "all three ad hoc builds finished successfully");

$stack->stop;

done_testing;
