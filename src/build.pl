#! @perl@ -w

use strict;
use File::Basename;
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});


sub isValidPath {
    my $path = shift;
    return system("nix-store --check-validity $path 2> /dev/null") == 0;
}


sub buildJob {
    my ($job) = @_;

    my $drvPath = $job->drvpath;
    my $outPath = $job->outpath;

    my $isCachedBuild = 1;
    my $outputCreated = 1; # i.e., the Nix build succeeded (but it could be a positive failure)
    my $startTime = 0;
    my $stopTime = 0;
    
    if (!isValidPath($outPath)) {
        $isCachedBuild = 0;

        $startTime = time();

        print "      BUILDING\n";

        my $res = system("nix-store --realise $drvPath");

        $stopTime = time();

        $outputCreated = $res == 0;
    }

    my $buildStatus;
    
    if ($outputCreated) {
        # "Positive" failures, e.g. the builder returned exit code 0
        # but flagged some error condition.
        $buildStatus = -e "$outPath/nix-support/failed" ? 2 : 0;
    } else {
        $buildStatus = 1; # = Nix failure
    }

    $db->txn_do(sub {
        my $build = $db->resultset('Builds')->create(
            { timestamp => time()
            , project => $job->project->name
            , jobset => $job->jobset->name
            , attrname => $job->attrname
            , description => $job->description
            , drvpath => $drvPath
            , outpath => $outPath
            , iscachedbuild => $isCachedBuild
            , buildstatus => $buildStatus
            , starttime => $startTime
            , stoptime => $stopTime
            , system => $job->system
            });
        print "      build ID = ", $build->id, "\n";

        foreach my $input ($job->inputs) {
            $input->job(undef);
            $input->build($build->id);
            $input->update;
        }

        my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
        if (-e $logPath) {
            print "      LOG $logPath\n";
            $db->resultset('Buildlogs')->create(
                { build => $build->id
                , logphase => "full"
                , path => $logPath
                , type => "raw"
                });
        }

        if ($outputCreated) {

            if (-e "$outPath/log") {
                foreach my $logPath (glob "$outPath/log/*") {
                    print "      LOG $logPath\n";
                    $db->resultset('Buildlogs')->create(
                        { build => $build->id
                        , logphase => basename($logPath)
                        , path => $logPath
                        , type => "raw"
                        });
                }
            }

            if (-e "$outPath/nix-support/hydra-build-products") {
                open LIST, "$outPath/nix-support/hydra-build-products" or die;
                while (<LIST>) {
                    /^(\w+)\s+([\w-]+)\s+(\S+)$/ or die;
                    my $type = $1;
                    my $subtype = $2;
                    my $path = $3;
                    die unless -e $path;
                    $db->resultset('Buildproducts')->create(
                        { build => $build->id
                        , type => $type
                        , subtype => $subtype
                        , path => $path
                        });
                }
                close LIST;
            } else {
                $db->resultset('Buildproducts')->create(
                    { build => $build->id
                    , type => "nix-build"
                    , subtype => ""
                    , path => $outPath
                    });
            }
        }

        $job->delete;
    });
}


my $jobId = $ARGV[0] or die;
print "building job $jobId\n";

# Lock the job.  If necessary, steal the lock from the parent process
# (runner.pl).  This is so that if the runner dies, the children
# (i.e. the job builders) can continue to run and won't have the lock
# taken away.
my $job;
$db->txn_do(sub {
    ($job) = $db->resultset('Jobs')->search({ id => $jobId });
    die "job $jobId doesn't exist" unless defined $job;
    if ($job->busy != 0 && $job->locker != getppid) {
        die "job $jobId is already being built";
    }
    $job->busy(1);
    $job->locker($$);
    $job->update;
});

die unless $job;

# Build the job.  If it throws an error, unlock the job so that it can
# be retried.
eval {
    print "BUILD\n";
    buildJob $job;
    print "DONE\n";
};
if ($@) {
    warn $@;
    $db->txn_do(sub {
        $job->busy(0);
        $job->locker($$);
        $job->update;
    });
}
