#! @perl@ -w

use strict;
use Cwd;
use POSIX qw(dup2);
use Hydra::Schema;


my $db = Hydra::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});

$db->storage->dbh->do("PRAGMA synchronous = OFF;");


# Unlock jobs whose building process has died.
$db->txn_do(sub {
    my @jobs = $db->resultset('Builds')->search(
        {finished => 0, busy => 1}, {join => 'schedulingInfo'});
    foreach my $job (@jobs) {
        my $pid = $job->schedulingInfo->locker;
        if (kill(0, $pid) != 1) { # see if we can signal the process
            print "job ", $job->id, " pid $pid died, unlocking\n";
            $job->schedulingInfo->busy(0);
            $job->schedulingInfo->locker("");
            $job->schedulingInfo->update;
        }
    }
});


sub checkJobs {
    print "looking for runnable jobs...\n";

    my @jobsStarted;
    my $logfile;

    $db->txn_do(sub {

        # Get the system types for the runnable builds.
        my @systemTypes = $db->resultset('Builds')->search(
            {finished => 0, busy => 0},
            {join => 'schedulingInfo', select => [{distinct => 'system'}], as => ['system']});

        # For each system type, select up to the maximum number of
        # concurrent build for that system type.  Choose the highest
        # priority builds first, then the oldest builds.
        foreach my $system (@systemTypes) {
            # How many builds are already currently executing for this
            # system type?
            my $nrActive = $db->resultset('Builds')->search(
                {finished => 0, busy => 1, system => $system->system},
                {join => 'schedulingInfo'})->count;

            # How many extra builds can we start?
            (my $systemTypeInfo) = $db->resultset('Systemtypes')->search({system => $system->system});
            my $maxConcurrent = defined $systemTypeInfo ? $systemTypeInfo->maxconcurrent : 2;
            my $extraAllowed = $maxConcurrent - $nrActive;
            $extraAllowed = 0 if $extraAllowed < 0;

            # Select the highest-priority builds to start.
            my @jobs = $extraAllowed == 0 ? () : $db->resultset('Builds')->search(
                { finished => 0, busy => 0, system => $system->system },
                { join => 'schedulingInfo', order_by => ["priority DESC", "timestamp"],
                  rows => $extraAllowed });

            print "system type `", $system->system,
                "': $nrActive active, $maxConcurrent allowed, ",
                "starting ", scalar(@jobs), " builds\n";

            foreach my $job (@jobs) {
                $logfile = getcwd . "/logs/" . $job->id;
                unlink $logfile;
                $job->schedulingInfo->busy(1);
                $job->schedulingInfo->locker($$);
                $job->schedulingInfo->logfile($logfile);
                $job->schedulingInfo->update;
                $job->buildsteps->delete_all;
                push @jobsStarted, $job;
            }
        }
    });

    # Actually start the builds we just selected.  We need to do this
    # outside the transaction in case it aborts or something.
    foreach my $job (@jobsStarted) {
        my $id = $job->id;
        print "starting job $id (", $job->project->name, ":", $job->attrname, ") on ", $job->system, "\n";
        eval {
            my $child = fork();
            die unless defined $child;
            if ($child == 0) {
                open LOG, ">$logfile" or die;
                POSIX::dup2(fileno(LOG), 1) or die;
                POSIX::dup2(fileno(LOG), 2) or die;
                exec("perl", "-IHydra/lib", "-w",
                     "./Hydra/programs/Build.pl", $id);
                warn "cannot start job " . $id;
                POSIX::_exit(1);
            }
        };
        if ($@) {
            warn $@;
            $db->txn_do(sub {
                $job->schedulingInfo->busy(0);
                $job->schedulingInfo->locker($$);
                $job->schedulingInfo->update;
            });
        }
    }
}


while (1) {
    eval {
        checkJobs;
    };
    warn $@ if $@;

    print "sleeping...\n";
    sleep(5);
}
