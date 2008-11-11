#! @perl@ -w

use strict;
use POSIX qw(dup2);
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});

$db->storage->dbh->do("PRAGMA synchronous = OFF;");


# Unlock jobs whose building process has died.
$db->txn_do(sub {
    my @jobs = $db->resultset('Jobs')->search({ busy => 1 });
    foreach my $job (@jobs) {
        my $pid = $job->locker;
        if (kill(0, $pid) != 1) { # see if we can signal the process
            print "job ", $job->id, " pid $pid died, unlocking\n";
            $job->busy(0);
            $job->locker("");
            $job->update;
        }
    }
});


sub checkJobs {
    print "looking for runnable jobs...\n";

    my $job;

    $db->txn_do(sub {
    
        my @jobs = $db->resultset('Jobs')->search({ busy => 0 }, {order_by => ["priority", "timestamp"]});

        print "# of available jobs: ", scalar(@jobs), "\n";

        if (scalar @jobs > 0) {
            $job = $jobs[0];
            $job->busy(1);
            $job->locker($$);
            $job->update;
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
                open LOG, ">logs/$id" or die;
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
                $job->busy(0);
                $job->locker($$);
                $job->update;
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
    sleep(10);
}
