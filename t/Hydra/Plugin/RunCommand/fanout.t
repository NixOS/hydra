use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Plugin::RunCommand;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "runcommand-dynamic.nix",
    build => 1
);

my $build = $builds->{"runCommandHook.example"};

is($build->job, "runCommandHook.example", "The only job should be runCommandHook.example");
is($build->finished, 1, "Build should be finished.");
is($build->buildstatus, 0, "Build should have buildstatus 0.");

subtest "fanoutToCommands" => sub {
    my $config = {
        runcommand => [
            {
                job => "",
                command => "foo"
            },
            {
                job => "*:*:*",
                command => "bar"
            },
            {
                job => "tests:basic:nomatch",
                command => "baz"
            }
        ]
    };

    is(
        Hydra::Plugin::RunCommand::fanoutToCommands(
            $config,
            "buildFinished",
            $build
        ),
        [
            {
                matcher => "",
                command => "foo"
            },
            {
                matcher => "*:*:*",
                command => "bar"
            }
        ],
        "fanoutToCommands returns a command per matching job"
    );
};

subtest "fanoutToCommandsWithDynamicRunCommandSupport" => sub {
    like(
        $build->buildoutputs->find({name => "out"})->path,
        qr/my-build-product$/,
        "The way we find the out path is reasonable"
    );

    my $config = {
        dynamicruncommand => { enable => 1 },
        runcommand => [
            {
                job => "*:*:*",
                command => "baz"
            }
        ]
    };

    is(
        Hydra::Plugin::RunCommand::fanoutToCommands(
            $config,
            "buildFinished",
            $build
        ),
        [
            {
                matcher => "*:*:*",
                command => "baz"
            },
            {
                matcher => "DynamicRunCommand(runCommandHook.example)",
                command => $build->buildoutputs->find({name => "out"})->path
            }
        ],
        "fanoutToCommands returns a command per matching job"
    );
};

subtest "isBuildEligibleForDynamicRunCommand" => sub {
    my $build = Hydra::Schema::Result::Builds->new({
        "job" => "foo bar baz"
    });

    is(
        Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($build),
        0,
        "The job name does not match"
    );

    $build->set_column("job", "runCommandHook");
    is(
        Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($build),
        0,
        "The job name does not match"
    );

    $build->set_column("job", "runCommandHook.");
    is(
        Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($build),
        0,
        "The job name does not match"
    );

    $build->set_column("job", "runCommandHook.a");
    is(
        Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($build),
        1,
        "The job name does match"
    );
};


done_testing;
