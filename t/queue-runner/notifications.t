use feature 'unicode_strings';
use strict;
use warnings;
use JSON;
use Setup;

my $binarycachedir = File::Temp->newdir();

my %ctx = test_init(
    nix_config => qq|
    experimental-features = nix-command
    substituters = file://${binarycachedir}?trusted=1
    |,
    hydra_config => q|
    use-substitutes = 1
    <runcommand>
      command = cp "$HYDRA_JSON" "$HYDRA_DATA/joboutput.json"
    </runcommand>
|);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

# Check that hydra's queue runner sends notifications.
# 
# The prelude to the test prebuilds one attribute and puts it in a
# binary cache. The jobset will try to build that job plus another,
# and we'll be able to check the behavior in both cases.
#
# Our test checks that the queue runner sends notifications even when the
# build it is performing can be substituted from a configured cache.
# To replicate this behavior we need to build an exact match of the
# derivation, upload it to a configured binary cache, then delete it
# locally. For completeness, we also verify that we can substitute
# the build locally.

subtest "Pre-build the job, upload to the cache, and then delete locally" => sub {
    my $scratchlogdir = File::Temp->newdir();
    $ENV{'NIX_LOG_DIR'} = "$scratchlogdir";

    my $outlink = "$ctx{tmpdir}/basic-canbesubstituted";
    is(system("nix-build '${ctx{jobsdir}}/notifications.nix' -A canbesubstituted --out-link '${outlink}'"), 0, "Building notifications.nix succeeded");
    is(system("nix copy --to 'file://${binarycachedir}' '${outlink}'"), 0, "Copying the closure to the binary cache succeeded");
    my $outpath = readlink($outlink);
    
    # Delete the store path and all of the system's garbage
    is(unlink($outlink), 1, "Deleting the GC root succeeds");
    is(system("nix log '$outpath'"), 0, "Reading the output's log succeeds");
    is(system("nix-store --delete '$outpath'"), 0, "Deleting the notifications.nix output succeeded");
    is(system("nix-collect-garbage"), 0, "Delete all the system's garbage");
};

subtest "Ensure substituting the job works, but reading the log fails" => sub {
    # Build the store path, with --max-jobs 0 to prevent builds
    my $outlink = "$ctx{tmpdir}/basic-canbesubstituted";
    is(system("nix-build '${ctx{jobsdir}}/notifications.nix' -A canbesubstituted --max-jobs 0 --out-link '${outlink}'"), 0, "Building notifications.nix succeeded");
    my $outpath = readlink($outlink);

    # Verify trying to read this path's log fails, since we substituted it
    isnt(system("nix log '$outpath'"), 0, "Reading the deleted output's log fails");

    # Delete the store path again and all of the store's garbage, ensuring
    # Hydra will try to build it.
    is(unlink($outlink), 1, "Deleting the GC root succeeds");
    is(system("nix-store --delete '$outpath'"), 0, "Deleting the basic output succeeded");
    is(system("nix-collect-garbage"), 0, "Delete all the system's garbage");
};

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $jobset = createBaseJobset("queue-runner-notifs", "notifications.nix", $ctx{jobsdir});

my $dbh = $db->storage->dbh;
$dbh->do("listen build_started");
$dbh->do("listen build_finished");
$dbh->do("listen step_finished");

subtest "Evaluation of the jobset" => sub {
    ok(evalSucceeds($jobset), "Evaluation should exit with return code 0");
    is(nrQueuedBuildsForJobset($jobset), 2, "Evaluation should result in 2 builds");
};

my @builds = queuedBuildsForJobset($jobset);


subtest "Build: substitutable, canbesubstituted" => sub {
    my ($build) = grep { $_->nixname eq "can-be-substituted" } @builds;
    ok(runBuild($build), "Build should exit with code 0");

    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

    # Verify that hydra-notify will process this job, even if hydra-notify isn't
    # running at the time.
    isnt($newbuild->notificationpendingsince, undef, "The build has a pending notification");

    subtest "First notification: build_finished" => sub {
        my ($channelName, $pid, $payload) = @{$dbh->func("pg_notifies")};
        is($channelName, "build_finished", "The event is for the build finishing");
        is($payload, $build->id, "The payload is the build's ID");
    };
};

subtest "Build: not substitutable, unsubstitutable" => sub {
    my ($build) = grep { $_->nixname eq "unsubstitutable" } @builds;
    ok(runBuild($build), "Build should exit with code 0");

    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

    # Verify that hydra-notify will process this job, even if hydra-notify isn't
    # running at the time.
    isnt($newbuild->notificationpendingsince, undef, "The build has a pending notification");

    subtest "First notification: build_started" => sub {
        my ($channelName, $pid, $payload) = @{$dbh->func("pg_notifies")};
        is($channelName, "build_started", "The event is for the build starting");
        is($payload, $build->id, "The payload is the build's ID");
    };

    subtest "Second notification: step_finished" => sub {
        my ($channelName, $pid, $payload) = @{$dbh->func("pg_notifies")};
        is($channelName, "step_finished", "The event is for the step finishing");
        my ($buildId, $stepNr, $logFile) = split "\t", $payload;
        is($buildId, $build->id, "The payload is the build's ID");
        is($stepNr, 1, "The payload is the build's step number");
        isnt($logFile, undef, "The log file is passed");
    };

    subtest "Third notification: build_finished" => sub {
        my ($channelName, $pid, $payload) = @{$dbh->func("pg_notifies")};
        is($channelName, "build_finished", "The event is for the build finishing");
        is($payload, $build->id, "The payload is the build's ID");
    };
};

done_testing;
