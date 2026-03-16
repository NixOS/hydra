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

# Enable dynamic runcommand on the project and jobset
$build->project->update({enable_dynamic_run_command => 1});
$build->jobset->update({enable_dynamic_run_command => 1});

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
    subtest "Non-matches based on name alone ..." => sub {
        my $build = $builds->{"foo-bar-baz"};
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
    };

    subtest "On outputs ..." => sub {
        ok(!warns {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.example"}),
                1,
                "out is an executable file"
            );
        }, "No warnings for an executable file.");

        ok(!warns {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.symlink"}),
                1,
                "out is a symlink to an executable file"
            );
        }, "No warnings for a symlink to an executable file.");

        like(warning {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.no-out"}),
                0,
                "No output named out"
            );
        }, qr/rejected: no output named 'out'/, "A relevant warning is provided for a missing output");

        like(warning {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.out-is-directory"}),
                0,
                "out is a directory"
            );
        }, qr/output is not a regular file or symlink/, "A relevant warning is provided for a directory output");

        like(warning {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.out-is-not-executable-file"}),
                0,
                "out is a file which is not a regular file or symlink"
            );
        }, qr/output is not executable/, "A relevant warning is provided if the file isn't executable");

        like(warning {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.symlink-non-executable"}),
                0,
                "out is a symlink to a non-executable file"
            );
        }, qr/output is not executable/, "A relevant warning is provided for symlinks to non-executables");

        like(warning {
            is(
                Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.symlink-directory"}),
                0,
                "out is a symlink to a directory"
            );
        }, qr/output is not a regular file or symlink/, "A relevant warning is provided for symlinks to directories");
    };

    subtest "On build status ..." => sub {
        is(
            Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.failed"}),
            0,
            "Failed builds don't get run"
        );
    };

    subtest "With dynamic runcommand disabled ..." => sub {
        subtest "disabled on the project, enabled on the jobset" => sub {
            $build->project->update({enable_dynamic_run_command => 0});
            $build->jobset->update({enable_dynamic_run_command => 1});


            like(warning {
                is(
                    Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.example"}),
                    0,
                    "Builds don't run from a jobset with disabled dynamic runcommand"
                );
            }, qr/project or jobset don't have dynamic runcommand enabled./, "A relevant warning is provided for a disabled runcommand support")
        };

        subtest "enabled on the project, disabled on the jobset" => sub {
            $build->project->update({enable_dynamic_run_command => 1});
            $build->jobset->update({enable_dynamic_run_command => 0});

            like(warning {
                is(
                    Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.example"}),
                    0,
                    "Builds don't run from a jobset with disabled dynamic runcommand"
                );
            }, qr/project or jobset don't have dynamic runcommand enabled./, "A relevant warning is provided for a disabled runcommand support")
        };

        subtest "disabled on the project, disabled on the jobset" => sub {
            $build->project->update({enable_dynamic_run_command => 0});
            $build->jobset->update({enable_dynamic_run_command => 0});

            like(warning {
                is(
                    Hydra::Plugin::RunCommand::isBuildEligibleForDynamicRunCommand($builds->{"runCommandHook.example"}),
                    0,
                    "Builds don't run from a jobset with disabled dynamic runcommand"
                );
            }, qr/project or jobset don't have dynamic runcommand enabled./, "A relevant warning is provided for a disabled runcommand support")
        };
    };
};


done_testing;
