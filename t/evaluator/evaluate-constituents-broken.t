use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

my $ctx = test_context();

my $jobsetCtx = $ctx->makeJobset(
    expression => 'constituents-broken.nix',
);
my $jobset = $jobsetCtx->{"jobset"};

my ($res, $stdout, $stderr) = captureStdoutStderr(60,
    ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
);
isnt($res, 0, "hydra-eval-jobset exits non-zero");
ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
like(
    $stderr,
    qr/aggregate job ‘mixed_aggregate’ failed with the error: constituentA: does not exist/,
    "The stderr record includes a relevant error message"
);

$jobset->discard_changes;  # refresh from DB
like(
    $jobset->errormsg,
    qr/aggregate job ‘mixed_aggregate’ failed with the error: constituentA: does not exist/,
    "The jobset records a relevant error message"
);

done_testing;
