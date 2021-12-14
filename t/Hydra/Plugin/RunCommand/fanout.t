use strict;
use warnings;
use Setup;

my %ctx = test_init();

use Test2::V0;
use Hydra::Plugin::RunCommand;

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("basic", "runcommand-dynamic.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/runcommand-dynamic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand-dynamic.nix should result in 1 build1");

(my $build) = queuedBuildsForJobset($jobset);

is($build->job, "runCommandHook.example", "The only job should be runCommandHook.example");
ok(runBuild($build), "Build should exit with return code 0");
my $newbuild = $db->resultset('Builds')->find($build->id);
is($newbuild->finished, 1, "Build should be finished.");
is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

subtest "fanoutToCommands" => sub {
    my $config = {
        runcommand => [
            {
                job => "",
                command => "foo"
            },
            {
                job => "tests:*:*",
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
            $newbuild
        ),
        [
            {
                matcher => "",
                command => "foo"
            },
            {
                matcher => "tests:*:*",
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
                job => "tests:basic:*",
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
                matcher => "tests:basic:*",
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
