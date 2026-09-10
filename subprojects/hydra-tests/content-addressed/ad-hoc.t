use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use AdHocContext;
use Hydra::Helper::Exec;
use Hydra::StorePath;

# A content-addressed derivation submitted through hydra-ad-hoc. Its
# output path is not known until it has been built; the queue runner
# records the resolved path in BuildStepOutputs / BuildOutputs, and
# that is what the daemon reports back.

my $ctx = test_context(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);
my $jobsdir = $ctx->jobsdir;

my $drv;
{
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        "nix-instantiate", "$jobsdir/content-addressed.nix", "-A", "empty_dir",
    );
    die "nix-instantiate failed: $stderr\n" if $res;
    chomp $stdout;
    $stdout =~ s/!.*$//;
    $drv = $stdout;
}
ok($drv =~ m{\.drv$}, "instantiated to $drv");

my $stack = AdHocContext->new($ctx);

my ($res, $stdout, $stderr) = $stack->run_cmd(900,
    "nix-store", "--realise", $drv,
);
if ($res) {
    chomp $stderr;
    diag("nix-store --realise failed: $stderr");
}
$stack->pump_logs;
is(($res // 0) + 0, 0, "nix-store --realise of a CA derivation via hydra-ad-hoc succeeds");

my $db = $ctx->db();
my ($build) = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc' },
    { join => 'jobset', order_by => 'me.id desc' },
);
ok(defined $build, "hydra-ad-hoc created an ad-hoc Builds row");
$build->discard_changes;
is($build->finished, 1, "the CA build is finished");
is($build->buildstatus, 0, "the CA build succeeded");

my %paths = map { $_->name => $_->path } $build->buildoutputs->all;
ok(defined $paths{out}, "BuildOutputs has a resolved path for 'out'");
my $out = printStorePath($ctx->db->storeDir, $paths{out});
my ($qres) = $ctx->capture_cmd(30, "nix-store", "--query", "--hash", $out);
is($qres, 0, "the resolved output path is valid in the central store: $out");

$stack->stop;

done_testing;
