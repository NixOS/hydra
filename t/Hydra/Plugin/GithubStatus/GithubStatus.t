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

done_testing;
