use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Plugin::GithubStatus;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

subtest "calculateContext" => sub {
    my $build = $builds->{"empty_dir"};
    my $build_id = $build->id;

    is(
        Hydra::Plugin::GithubStatus::calculateContext($build, "my-job-name", {}),
        "continuous-integration/hydra:my-job-name:${build_id}",
        "An empty configuration produces a default result"
    );

    is(
        Hydra::Plugin::GithubStatus::calculateContext($build, "my-job-name", {
            useShortContext => 1
        }),
        "ci/hydra:my-job-name:${build_id}",
        "useShortContext=1 uses abbreviates continuous-integration"
    );

    is(
        Hydra::Plugin::GithubStatus::calculateContext($build, "my-job-name", {
            excludeBuildFromContext => 1
        }),
        "continuous-integration/hydra:my-job-name",
        "excludeBuildFromContext=1 removes the build ID"
    );

    is(
        Hydra::Plugin::GithubStatus::calculateContext($build, "my-job-name", {
            context => "my special context"
        }),
        "my special context",
        "context=... replaces  any other context"
    );
};

subtest "statusBody" => sub {
    my $build = $builds->{"empty_dir"};

    is(
        Hydra::Plugin::GithubStatus::statusBody(0, $build, "base-url", {}, "my-job-name", "some context"),
        {
            state => "pending",
            target_url => "base-url/build/${\$build->id}",
            description => "Hydra build #${\$build->id} of my-job-name",
            context => "some context"
        },
        "A pending build"
    );

    is(
        Hydra::Plugin::GithubStatus::statusBody(1, $build, "base-url", {}, "my-job-name", "some context"),
        {
            state => "success",
            target_url => "base-url/build/${\$build->id}",
            description => "Hydra build #${\$build->id} of my-job-name",
            context => "some context"
        },
        "A successful build"
    );

    is(
        Hydra::Plugin::GithubStatus::statusBody(1, $build, "base-url", {
            description => "overloaded description!"
        }, "my-job-name", "some context"),
        {
            state => "success",
            target_url => "base-url/build/${\$build->id}",
            description => "overloaded description!",
            context => "some context"
        },
        "Overloaded description"
    );
};

subtest "extractGithubArgsFromFlake" => sub {
    my @failingInputs = (
        '',
        'git@github.com:NixOS/hydra.git'
    );
    for my $input (@failingInputs) {
        my $githubArgs = Hydra::Plugin::GithubStatus::extractGithubArgsFromFlake($input);
        ok(!defined($githubArgs), "$input is not an extractable flake ref");
    };

    my $passingInputs = {
        'github:NixOS/hydra/90aa8592925a688c37e8d93822d19bd74e25fca7' => {
            owner => "NixOS",
            repo => "hydra",
            rev => "90aa8592925a688c37e8d93822d19bd74e25fca7"
        },
        'git+ssh://git@github.com/NixOS/hydra?rev=90aa8592925a688c37e8d93822d19bd74e25fca7' => {
            owner => "NixOS",
            repo => "hydra",
            rev => "90aa8592925a688c37e8d93822d19bd74e25fca7"
        },
        'git+ssh://git@github.com/NixOS/hydra?randomjunkseemsokayhererev=90aa8592925a688c37e8d93822d19bd74e25fca7' => {
            owner => "NixOS",
            repo => "hydra",
            rev => "90aa8592925a688c37e8d93822d19bd74e25fca7"
        },
    };
    for my $flakeref (keys %$passingInputs) {
        my $expectedArgs = $passingInputs->{$flakeref};
        is(
            Hydra::Plugin::GithubStatus::extractGithubArgsFromFlake($flakeref),
            $expectedArgs,
            "$flakeref: the GitHub args matched"
        );
    };
};

done_testing;
