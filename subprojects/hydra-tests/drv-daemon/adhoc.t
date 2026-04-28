use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use DrvDaemonContext;
use Hydra::Helper::Exec;

# Imperative ad-hoc build: nix-store --realise against the drv-daemon
# socket lands the build in the auto-created `adhoc/adhoc` jobset, the
# queue runner picks it up like any other Build, and the daemon
# returns once the row is finished.
#
# This path doesn't go through hydra-evaluator at all.

my $ctx = test_context();
my $jobsdir = $ctx->jobsdir;

my $drv;
{
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        "nix-instantiate", "$jobsdir/drv-daemon/adhoc.nix", "-A", "hello",
    );
    if ($res) {
        chomp $stderr;
        diag("nix-instantiate failed: $stderr");
        die "nix-instantiate failed\n";
    }
    chomp $stdout;
    $stdout =~ s/!.*$//;
    $drv = $stdout;
}

ok($drv =~ m{\.drv$}, "instantiated to $drv");

my $stack = DrvDaemonContext->new($ctx);

my ($res, $stdout, $stderr) = $stack->run_cmd(900,
    "nix-store", "--realise", $drv,
);
if ($res) {
    chomp $stderr;
    diag("nix-store --realise failed: $stderr");
}
$stack->pump_logs;
is(($res // 0) + 0, 0, "nix-store --realise via drv-daemon succeeds");

my @output_paths = grep { /\.drv$/ ? 0 : 1 } split /\n/, ($stdout // "");
ok(scalar(@output_paths) >= 1, "nix-store printed at least one output path");
for my $p (@output_paths) {
    ok(-e $p, "output path exists: $p");
}

my $db = $ctx->db();
my @builds = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc' },
    { join => 'jobset', order_by => 'me.id desc' },
);
ok(scalar(@builds) >= 1, "drv-daemon created an ad-hoc Builds row");

my $build = $builds[0];
$build->discard_changes;
is($build->finished, 1, "ad-hoc build is marked finished");
is($build->buildstatus, 0, "ad-hoc build succeeded");
is($build->drvpath, $drv, "ad-hoc build drvpath matches the submitted derivation");
is($build->keep, 1, "ad-hoc build is marked keep=1 so its outputs survive gc");

# hydra-update-gc-roots roots kept outputs via BuildOutputs.
my @outputs = $build->buildoutputs->all;
ok(scalar(@outputs) >= 1, "ad-hoc build has at least one BuildOutputs row");
my %paths = map { $_->name => $_->path } @outputs;
ok(defined $paths{out}, "BuildOutputs row for 'out' has a path recorded");
ok($paths{out} && -e $paths{out}, "recorded BuildOutputs path exists on disk");

# The daemon socket gates ad-hoc build submission, so it must not be world-writable.
my @sb = stat($stack->daemon_socket);
ok(scalar(@sb) > 0, "daemon socket is stat-able");
is($sb[2] & 07777, 0660, "daemon socket is mode 0660 (group-rw, other-none)");

$stack->stop;

done_testing;
