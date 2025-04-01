use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

my $ctx = test_context();

subtest "broken constituents expression" => sub {
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
        qr/aggregate job 'mixed_aggregate' references non-existent job 'constituentA'/,
        "The stderr record includes a relevant error message"
    );

    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    like(
        $jobset->errormsg,
        qr/aggregate job ‘mixed_aggregate’ failed with the error: constituentA: does not exist/,
        "The jobset records a relevant error message"
    );
};

subtest "no matches" => sub {
    my $jobsetCtx = $ctx->makeJobset(
        expression => 'constituents-no-matches.nix',
    );
    my $jobset = $jobsetCtx->{"jobset"};

    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
    );
    isnt($res, 0, "hydra-eval-jobset exits non-zero");
    ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
    like(
        $stderr,
        qr/aggregate job 'non_match_aggregate' references constituent glob pattern 'tests\.\*' with no matches/,
        "The stderr record includes a relevant error message"
    );

    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    like(
        $jobset->errormsg,
        qr/aggregate job ‘non_match_aggregate’ failed with the error: tests\.\*: constituent glob pattern had no matches/,
        qr/in job ‘non_match_aggregate’:\ntests\.\*: constituent glob pattern had no matches/,
        "The jobset records a relevant error message"
    );
};

done_testing;
