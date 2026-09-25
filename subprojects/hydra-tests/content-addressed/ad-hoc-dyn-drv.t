use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use AdHocContext;
use Hydra::Helper::Exec;
use Hydra::StorePath;

# A dynamic derivation asked for directly: `producer^out^out` names the
# output of whatever `.drv` the producer writes. A Builds row can only
# name a `.drv` that exists, so the daemon has to build the producer
# first, read the produced `.drv` from its outputs, and only then file
# the build the client actually asked for. Two ad hoc builds result.

my $ctx = test_context(
    nix_config => qq|
    experimental-features = nix-command ca-derivations dynamic-derivations
    |,
);
my $jobsdir = $ctx->jobsdir;

my $producer;
{
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        "nix-instantiate", "$jobsdir/ad-hoc/dyn-drv.nix", "-A", "producer",
    );
    die "nix-instantiate failed: $stderr\n" if $res;
    chomp $stdout;
    $stdout =~ s/!.*$//;
    $producer = $stdout;
}
ok($producer =~ m{\.drv$}, "instantiated the producer: $producer");

my $stack = AdHocContext->new($ctx);

# `nix-store --realise` cannot spell a nested derived path; `nix build` can.
my ($res, $stdout, $stderr) = $stack->run_cmd(900,
    "nix", "build", "--no-link", "--print-out-paths", "$producer^out^out",
);
if ($res) {
    chomp $stderr;
    diag("nix build failed: $stderr");
}
$stack->pump_logs;
is(($res // 0) + 0, 0, "nix build of a dynamic derivation via hydra-ad-hoc succeeds");

my $db = $ctx->db();
my @builds = $db->resultset('Builds')->search(
    { 'jobset.project' => 'adhoc', 'jobset.name' => 'adhoc' },
    { join => 'jobset', order_by => 'me.id' },
);
is(scalar(@builds), 2, "two ad hoc builds: the producer, then the derivation it produced");
if (@builds == 2) {
    my ($first, $second) = @builds;
    $_->discard_changes for @builds;
    is(printStorePath($ctx->db->storeDir, $first->drvpath), $producer,
        "the first build is the producer");
    is($first->buildstatus, 0, "the producer succeeded");
    my %out = map { $_->name => printStorePath($ctx->db->storeDir, $_->path) } $first->buildoutputs->all;
    is(printStorePath($ctx->db->storeDir, $second->drvpath), $out{out},
        "the second build is the .drv the producer wrote");
    is($second->buildstatus, 0, "the produced derivation succeeded");
}

chomp(my $out_path = $stdout // "");
ok($out_path =~ m{/nix/store/}, "the client was told the final output path: $out_path");
my ($qres) = $ctx->capture_cmd(30, "nix-store", "--query", "--hash", $out_path);
is($qres, 0, "the final output path is valid in the central store");

$stack->stop;

done_testing;
