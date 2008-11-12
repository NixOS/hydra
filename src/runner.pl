#! @perl@ -w

use strict;
use Cwd;
use POSIX qw(dup2);
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});

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

    my $job;
    my $logfile;

    $db->txn_do(sub {
    
        my @jobs = $db->resultset('Builds')->search(
            {finished => 0, busy => 0},
            {join => 'schedulingInfo', order_by => ["priority", "timestamp"]});

        print "# of available jobs: ", scalar(@jobs), "\n";

        if (scalar @jobs > 0) {
            $job = $jobs[0];
            $logfile = getcwd . "/logs/" . $job->id;
            unlink $logfile;
            $job->schedulingInfo->busy(1);
            $job->schedulingInfo->locker($$);
            $job->schedulingInfo->logfile($logfile);
            $job->schedulingInfo->update;
        }

    });

    # Start the job.  We need to do this outside the transaction in
    # case it aborts or something.
    if (defined $job) {
        my $id = $job->id;
        print "starting job $id\n";
        eval {
            my $child = fork();
            die unless defined $child;
            if ($child == 0) {
                open LOG, ">$logfile" or die;
                POSIX::dup2(fileno(LOG), 1) or die;
                POSIX::dup2(fileno(LOG), 2) or die;
                exec("perl", "-IHydraFrontend/lib", "-w",
                     "./build.pl", $id);
                warn "cannot start job " . $id;
                _exit(1);
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
