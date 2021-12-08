use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Plugin::RunCommand;

subtest "isEnabled" => sub {
    is(
        Hydra::Plugin::RunCommand::isEnabled({}),
        0,
        "Disabled by default."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => {}}),
        0,
        "Disabled by default."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => { runcommand => {}}}),
        1,
        "Enabled if any runcommand blocks exist."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => { dynamicruncommand => {}}}),
        0,
        "Not enabled if an empty dynamicruncommand blocks exist."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => { dynamicruncommand => { enable => 0 }}}),
        0,
        "Not enabled if a dynamicruncommand blocks exist without enable being set to 1."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => { dynamicruncommand => { enable => 1 }}}),
        1,
        "Enabled if a dynamicruncommand blocks exist with enable being set to 1."
    );

    is(
        Hydra::Plugin::RunCommand::isEnabled({ config => {
            runcommand => {},
            dynamicruncommand => { enable => 0 }
        }}),
        1,
        "Enabled if a runcommand config block exists, even if a dynamicruncommand is explicitly disabled."
    );
};

subtest "areStaticCommandsEnabled" => sub {
    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({}),
        0,
        "Disabled by default."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({}),
        0,
        "Disabled by default."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({ runcommand => {}}),
        1,
        "Enabled if any runcommand blocks exist."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({ dynamicruncommand => {}}),
        0,
        "Not enabled by dynamicruncommand blocks."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({ dynamicruncommand => { enable => 0 }}),
        0,
        "Not enabled by dynamicruncommand blocks."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({ dynamicruncommand => { enable => 1 }}),
        0,
        "Not enabled by dynamicruncommand blocks."
    );

    is(
        Hydra::Plugin::RunCommand::areStaticCommandsEnabled({
            runcommand => {},
            dynamicruncommand => { enable => 0 }
        }),
        1,
        "Enabled if a runcommand config block exists, even if a dynamicruncommand is explicitly disabled."
    );
};

subtest "areDynamicCommandsEnabled" => sub {
    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({}),
        0,
        "Disabled by default."
    );

    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({ runcommand => {}}),
        0,
        "Disabled even if any runcommand blocks exist."
    );

    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({ dynamicruncommand => {}}),
        0,
        "Not enabled if an empty dynamicruncommand blocks exist."
    );

    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({ dynamicruncommand => { enable => 0 }}),
        0,
        "Not enabled if a dynamicruncommand blocks exist without enable being set to 1."
    );

    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({ dynamicruncommand => { enable => 1 }}),
        1,
        "Enabled if a dynamicruncommand blocks exist with enable being set to 1."
    );

    is(
        Hydra::Plugin::RunCommand::areDynamicCommandsEnabled({
            runcommand => {},
            dynamicruncommand => { enable => 0 }
        }),
        0,
        "Disabled if dynamicruncommand is explicitly disabled."
    );
};

subtest "configSectionMatches" => sub {
    subtest "Expected matches" => sub {
        my @examples = (
            # Exact match
            ["project:jobset:job", "project", "jobset", "job"],

            # One wildcard
            ["project:jobset:*", "project", "jobset", "job"],
            ["project:*:job", "project", "jobset", "job"],
            ["*:jobset:job", "project", "jobset", "job"],

            # Two wildcards
            ["project:*:*", "project", "jobset", "job"],
            ["*:*:job", "project", "jobset", "job"],

            # Three wildcards
            ["*:*:*", "project", "jobset", "job"],

            # Implicit wildcards
            ["", "project", "jobset", "job"],
            ["project", "project", "jobset", "job"],
            ["project:jobset", "project", "jobset", "job"],
        );

        for my $example (@examples) {
            my ($matcher, $project, $jobset, $job) = @$example;

            is(
                Hydra::Plugin::RunCommand::configSectionMatches(
                    $matcher, $project, $jobset, $job
                ),
                1,
                "Expecting $matcher to match $project:$jobset:$job"
            );
        }
    };

    subtest "Fails to match" => sub {
        my @examples = (
            # Literal string non-matches
            ["project:jobset:job", "project", "jobset", "nonmatch"],
            ["project:jobset:job", "project", "nonmatch", "job"],
            ["project:jobset:job", "nonmatch", "jobset", "job"],

            # Wildcard based non-matches
            ["*:*:job", "project", "jobset", "nonmatch"],
            ["*:jobset:*", "project", "nonmatch", "job"],
            ["project:*:*", "nonmatch", "jobset", "job"],

            # These wildcards are NOT regular expressions
            ["*:*:j.*", "project", "jobset", "job"],
            [".*:.*:.*", "project", "nonmatch", "job"],
        );

        for my $example (@examples) {
            my ($matcher, $project, $jobset, $job) = @$example;

            is(
                Hydra::Plugin::RunCommand::configSectionMatches(
                    $matcher, $project, $jobset, $job
                ),
                0,
                "Expecting $matcher to not match $project:$jobset:$job"
            );
        }

        like(
            dies {
                Hydra::Plugin::RunCommand::configSectionMatches(
                    "foo:bar:baz:tux", "foo", "bar", "baz"
                ),
            },
            qr/invalid section name/,
            "A matcher must have no more than 3 sections"
        );
    };
};

subtest "eventMatches" => sub {
    # This is probably a misfeature that isn't very useful but let's test
    # it anyway. At best this lets you make a RunCommand event not work
    # by specifying the "events" key. Note: By testing it I'm not promising
    # it'll keep working. In fact, I wouldn't be surprised if we chose to
    # delete this support since RunCommand never runs on any event other
    # than buildFinished.
    is(
        Hydra::Plugin::RunCommand::eventMatches({}, "buildFinished"),
        1,
        "An unspecified events key matches"
    );

    is(
        Hydra::Plugin::RunCommand::eventMatches({ events => ""}, "buildFinished"),
        0,
        "An empty events key does not match"
    );

    is(
        Hydra::Plugin::RunCommand::eventMatches({ events => "foo bar buildFinished baz"}, "buildFinished"),
        1,
        "An events key with multiple events does match when buildFinished is present"
    );

    is(
        Hydra::Plugin::RunCommand::eventMatches({ events => "foo bar baz"}, "buildFinished"),
        0,
        "An events key with multiple events does not match when buildFinished is missing"
    );
};

done_testing;
