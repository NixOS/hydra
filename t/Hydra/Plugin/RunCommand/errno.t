use feature 'unicode_strings';
use strict;
use warnings;
use JSON::MaybeXS;
use Setup;

my %ctx = test_init(
    hydra_config => q|
    <runcommand>
      command = invalid-command-this-does-not-exist
    </runcommand>
|
);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({ name => "tests", displayname => "", owner => "root" });

# Most basic test case, no parameters
my $jobset = createBaseJobset("basic", "runcommand.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/runcommand.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand.nix should result in 1 build1");

(my $build) = queuedBuildsForJobset($jobset);

is($build->job, "metrics", "The only job should be metrics");
ok(runBuild($build), "Build should exit with return code 0");
my $newbuild = $db->resultset('Builds')->find($build->id);
is($newbuild->finished,    1, "Build should be finished.");
is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

ok(sendNotifications(), "Notifications execute successfully.");

subtest "Validate a run log was created" => sub {
    my $runlog = $build->runcommandlogs->find({});
    ok(!$runlog->did_succeed(),             "The process did not succeed.");
    ok($runlog->did_fail_with_exec_error(), "The process failed to start due to an exec error.");
    is($runlog->job_matcher, "*:*:*",                               "An unspecified job matcher is defaulted to *:*:*");
    is($runlog->command,     'invalid-command-this-does-not-exist', "The executed command is saved.");
    is($runlog->start_time,  within(time() - 1, 2),                 "The start time is recent.");
    is($runlog->end_time,    within(time() - 1, 2),                 "The end time is also recent.");
    is($runlog->exit_code,   undef,                                 "This command should not have executed.");
    is($runlog->error_number, 2,                                    "This command failed to exec.");
};

done_testing;
