use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use AdHocContext;
use Hydra::Helper::Exec;
use Hydra::StorePath;

# Imperative ad-hoc build: nix-store --realise against the hydra-ad-hoc
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
        "nix-instantiate", "$jobsdir/ad-hoc/hello.nix", "-A", "hello",
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

my $stack = AdHocContext->new($ctx);

# `internal-json` makes the client print every log message the daemon
# sends, so the live build log can be checked below.
my ($res, $stdout, $stderr) = $stack->run_cmd(900,
    "nix-store", "--realise", $drv, "--log-format", "internal-json",
);
if ($res) {
    chomp $stderr;
    diag("nix-store --realise failed: $stderr");
}
$stack->pump_logs;
is(($res // 0) + 0, 0, "nix-store --realise via hydra-ad-hoc succeeds");

my @output_paths = grep { /\.drv$/ ? 0 : 1 } split /\n/, ($stdout // "");
ok(scalar(@output_paths) >= 1, "nix-store printed at least one output path");
# The central store is a chroot, so ask it rather than poking the filesystem.
sub is_valid_in_central {
    my ($p) = @_;
    my ($qres) = $ctx->capture_cmd(30, "nix-store", "--query", "--hash", $p);
    return $qres == 0;
}
for my $p (@output_paths) {
    ok(is_valid_in_central($p), "output path is valid in the central store: $p");
}

my $db = $ctx->db();
my @builds = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc' },
    { join => 'jobset', order_by => 'me.id desc' },
);
ok(scalar(@builds) >= 1, "hydra-ad-hoc created an ad-hoc Builds row");

my $build = $builds[0];
$build->discard_changes;
is($build->finished, 1, "ad-hoc build is marked finished");
is($build->buildstatus, 0, "ad-hoc build succeeded");
is(printStorePath($ctx->db->storeDir, $build->drvpath), $drv,
    "ad-hoc build drvpath matches the submitted derivation");
is($build->keep, 1, "ad-hoc build is marked keep=1 so its outputs survive gc");

# hydra-update-gc-roots roots kept outputs via BuildOutputs.
my @outputs = $build->buildoutputs->all;
ok(scalar(@outputs) >= 1, "ad-hoc build has at least one BuildOutputs row");
my %paths = map { $_->name => printStorePath($ctx->db->storeDir, $_->path) } @outputs;
ok(defined $paths{out}, "BuildOutputs row for 'out' has a path recorded");
ok($paths{out} && is_valid_in_central($paths{out}), "recorded BuildOutputs path is valid in the central store");

# While the client waited, the daemon streamed the build step's log as
# Nix activity messages: a `Build` activity (type 105) for the
# derivation, and its log lines as `BuildLogLine` results (type 101).
# With `--log-format internal-json` the client echoes each as a
# `@nix {...}` line on stderr.
my @json = map { s/^\@nix //r } grep { /^\@nix / } split /\n/, ($stderr // "");
ok(scalar(@json) > 0, "the client received log messages from the daemon");
# Keys are emitted in alphabetical order, so match them separately.
ok((grep { /"action":"start"/ && /"type":105/ } @json),
    "a Build activity was started for the step");
my @log_lines = grep { /"action":"result"/ && /"type":101/ } @json;
ok((grep { /hello from hydra-ad-hoc, live/ } @log_lines),
    "the step's stdout reached the client as a build log line")
    or diag("client log lines:\n" . join("\n", @log_lines));
ok((grep { /"action":"stop"/ } @json), "the Build activity was stopped");

# The daemon socket gates ad-hoc build submission, so it must not be world-writable.
my @sb = stat($stack->daemon_socket);
ok(scalar(@sb) > 0, "daemon socket is stat-able");
is($sb[2] & 07777, 0660, "daemon socket is mode 0660 (group-rw, other-none)");

$stack->stop;

done_testing;
