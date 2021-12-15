use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

subtest "Build: succeed_with_failed" => sub {
    my $build = $builds->{"succeed_with_failed"};

    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 6, "succeeeded-but-failed should have buildstatus 6.");
};

subtest "Build: empty_dir" => sub {
    my $build = $builds->{"empty_dir"};

    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 0, "Should have succeeded.");
};

subtest "Build: fails" => sub {
    my $build = $builds->{"fails"};

    is($build->finished, 1, "Build should be finished.");
    is($build->buildstatus, 1, "Should have failed.");
};

done_testing;
