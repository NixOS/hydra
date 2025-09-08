use strict;
use warnings;
use Setup;
use Test2::V0;

use Hydra::Helper::BuildDiff;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

subtest "empty diff" => sub {
    my $ret = buildDiff([], []);
    is(
        $ret,
        {
            stillSucceed => [],
            stillFail => [],
            nowSucceed => [],
            nowFail => [],
            new => [],
            removed => [],
            unfinished => [],
            aborted => [],

            totalAborted => 0,
            totalFailed => 0,
            totalQueued => 0,
        },
        "empty list of jobs returns empty diff"
    );
};

subtest "2 different jobs" => sub {
    my $ret = buildDiff([$builds->{"succeed_with_failed"}], [$builds->{"empty_dir"}]);

    is($ret->{stillSucceed}, [], "stillSucceed");
    is($ret->{stillFail}, [], "stillFail");
    is($ret->{nowSucceed}, [], "nowSucceed");
    is($ret->{nowFail}, [], "nowFail");
    is($ret->{unfinished}, [], "unfinished");
    is($ret->{aborted}, [], "aborted");

    is(scalar(@{$ret->{new}}), 1, "list of new jobs is 1 element long");
    is(
        $ret->{new}[0]->get_column('id'),
        $builds->{"succeed_with_failed"}->get_column('id'),
        "succeed_with_failed is a new job"
    );

    is($ret->{totalFailed}, 1, "total failed jobs is 1");

    is(
        $ret->{removed},
        [
            {
                job => $builds->{"empty_dir"}->get_column('job'),
                system => $builds->{"empty_dir"}->get_column('system')
            }
        ],
        "empty_dir is a removed job"
    );
};

subtest "failed job with no previous history" => sub {
    my $ret = buildDiff([$builds->{"fails"}], []);

    is($ret->{totalFailed}, 1, "total failed jobs is 1");
    is(
        $ret->{new}[0]->get_column('id'),
        $builds->{"fails"}->get_column('id'),
        "fails is a failed job"
    );
};

subtest "not-yet-built job with no previous history" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "build-products.nix",
        build => 0
    );

    my $ret = buildDiff([$builds->{"simple"}], []);

    is($ret->{stillSucceed}, [], "stillSucceed");
    is($ret->{stillFail}, [], "stillFail");
    is($ret->{nowSucceed}, [], "nowSucceed");
    is($ret->{nowFail}, [], "nowFail");
    is($ret->{removed}, [], "removed");
    is($ret->{unfinished}, [], "unfinished");
    is($ret->{aborted}, [], "aborted");

    is(scalar(@{$ret->{new}}), 1, "list of new jobs is 1 element long");
    is(
        $ret->{new}[0]->get_column('id'),
        $builds->{"simple"}->get_column('id'),
        "simple is a new job"
    );
};

done_testing;
