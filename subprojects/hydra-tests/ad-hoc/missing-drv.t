use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use AdHocContext;

# Ask hydra-ad-hoc to realise a .drv that is not in the store. Nix sends
# `BuildPaths` even after `QueryMissing` reported the path unknown, so
# the daemon has to refuse it itself: a Builds row for a .drv nobody
# has can only ever be aborted by the queue runner, and until it is the
# client sits waiting. The right answer is an immediate error and no
# row at all.

my $ctx = test_context();
my $stack = AdHocContext->new($ctx);

# A well-formed store path (valid hash, plausible name) that was never
# added to the store.
my $store_dir = $ctx->{central}{nix_store_dir};
my $drv = "$store_dir/q0r4vvmizrbsh8msrnn5s4q1xmsc8zhr-does-not-exist.drv";

my $t0 = time();
my ($res, $stdout, $stderr) = $stack->run_cmd(60,
    "nix-store", "--realise", $drv,
);
my $elapsed = time() - $t0;
$stack->pump_logs;

isnt(($res // 0) + 0, 0, "nix-store --realise of a missing .drv fails");
like($stderr // "", qr/not present in the upstream store/,
    "the daemon says the .drv is missing");
ok($elapsed < 30, "it fails promptly rather than waiting on the queue runner (${elapsed}s)");

my $db = $ctx->db();
my $rows = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc' },
    { join => 'jobset' },
)->count;
is($rows, 0, "no Builds row was filed for the missing .drv");

$stack->stop;

done_testing;
