#! @perl@ -w

use strict;
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});


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


while (1) {

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
        print "starting job ", $job->id, "\n";
        eval {
            system("perl -I HydraFrontend/lib -w ./build.pl " . $job->id);
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

    print "sleeping...\n";
    sleep(10);
}
