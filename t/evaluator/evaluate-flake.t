use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use File::Copy qw(cp);

my $ctx = test_context(
    nix_config => qq|
    experimental-features = nix-command flakes
    |,
    hydra_config => q|
    <runcommand>
      evaluator_pure_eval = false
    </runcommand>
    |
);

sub checkFlake {
    my ($flake) = @_;

    cp($ctx->jobsdir . "/basic.nix", $ctx->jobsdir . "/" . $flake);
    cp($ctx->jobsdir . "/config.nix", $ctx->jobsdir . "/" . $flake);
    cp($ctx->jobsdir . "/empty-dir-builder.sh", $ctx->jobsdir . "/" . $flake);
    cp($ctx->jobsdir . "/fail.sh", $ctx->jobsdir . "/" . $flake);
    cp($ctx->jobsdir . "/succeed-with-failed.sh", $ctx->jobsdir . "/" . $flake);

    chmod 0755, $ctx->jobsdir . "/" . $flake . "/empty-dir-builder.sh";
    chmod 0755, $ctx->jobsdir . "/" . $flake . "/fail.sh";
    chmod 0755, $ctx->jobsdir . "/" . $flake . "/succeed-with-failed.sh";

    my $builds = $ctx->makeAndEvaluateJobset(
        flake => 'path:' . $ctx->jobsdir . "/" . $flake,
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
}

subtest "Flake using `checks`" => sub {
    checkFlake 'flake-checks'
};

subtest "Flake using `hydraJobs`" => sub {
    checkFlake 'flake-hydraJobs'
};

done_testing;
