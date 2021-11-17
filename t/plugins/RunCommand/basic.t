use feature 'unicode_strings';
use strict;
use warnings;
use JSON::MaybeXS;
use Setup;

my %ctx = test_init(
    hydra_config => q|
    <runcommand>
      command = cp "$HYDRA_JSON" "$HYDRA_DATA/joboutput.json"
    </runcommand>
|);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Most basic test case, no parameters
my $jobset = createBaseJobset("basic", "runcommand.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/runcommand.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand.nix should result in 1 build1");

(my $build) = queuedBuildsForJobset($jobset);

is($build->job, "metrics", "The only job should be metrics");
ok(runBuild($build), "Build should exit with return code 0");
my $newbuild = $db->resultset('Builds')->find($build->id);
is($newbuild->finished, 1, "Build should be finished.");
is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

ok(sendNotifications(), "Notifications execute successfully.");

my $dat = do {
    my $filename = $ENV{'HYDRA_DATA'} . "/joboutput.json";
    open(my $json_fh, "<", $filename)
        or die("Can't open \"$filename\": $!\n");
    local $/;
    my $json = JSON::MaybeXS->new;
    $json->decode(<$json_fh>)
};

subtest "Validate the file parsed and at least one field matches" => sub {
    is($dat->{build}, $newbuild->id, "The build event matches our expected ID.");
};

subtest "Validate a run log was created" => sub {
    my $runlog = $build->runcommandlogs->find({});
    is($runlog->job_matcher, "*:*:*", "An unspecified job matcher is defaulted to *:*:*");
    is($runlog->command, 'cp "$HYDRA_JSON" "$HYDRA_DATA/joboutput.json"', "The executed command is saved.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is also recent.");
    is($runlog->exit_code, 0, "This command should have succeeded.");
};

done_testing;
