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
            failed => [],
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

    is(scalar(@{$ret->{failed}}), 1, "list of failed jobs is 1 element long");
    is(
        $ret->{failed}[0]->get_column('id'),
        $builds->{"succeed_with_failed"}->get_column('id'),
        "succeed_with_failed is a failed job"
    );

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

done_testing;
