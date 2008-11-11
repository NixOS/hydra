#! @perl@ -w

use strict;
use File::Basename;
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});

$db->storage->dbh->do("PRAGMA synchronous = OFF;");


sub isValidPath {
    my $path = shift;
    return system("nix-store --check-validity $path 2> /dev/null") == 0;
}


sub doBuild {
    my ($build) = @_;

    my $drvPath = $build->drvpath;
    my $outPath = $build->outpath;

    my $isCachedBuild = 1;
    my $outputCreated = 1; # i.e., the Nix build succeeded (but it could be a positive failure)
    my $startTime = 0;
    my $stopTime = 0;
    
    if (!isValidPath($outPath)) {
        $isCachedBuild = 0;

        $startTime = time();

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
        $build->finished(1);
        $build->timestamp(time());
        $build->update;

        $db->resultset('Buildresultinfo')->create(
            { id => $build->id
            , iscachedbuild => $isCachedBuild
            , buildstatus => $buildStatus
            , starttime => $startTime
            , stoptime => $stopTime
            });

        my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
        if (-e $logPath) {
            print "found log $logPath\n";
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
                    print "found log $logPath\n";
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
            } elsif ($buildStatus == 0) {
                $db->resultset('Buildproducts')->create(
                    { build => $build->id
                    , type => "nix-build"
                    , subtype => ""
                    , path => $outPath
                    });
            }
        }

        $build->schedulingInfo->delete;
    });
}


my $buildId = $ARGV[0] or die;
print "performing build $buildId\n";

# Lock the build.  If necessary, steal the lock from the parent
# process (runner.pl).  This is so that if the runner dies, the
# children (i.e. the build.pl instances) can continue to run and won't
# have the lock taken away.
my $build;
$db->txn_do(sub {
    ($build) = $db->resultset('Builds')->search({id => $buildId});
    die "build $buildId doesn't exist" unless defined $build;
    if ($build->schedulingInfo->busy != 0 && $build->schedulingInfo->locker != getppid) {
        die "build $buildId is already being built";
    }
    $build->schedulingInfo->busy(1);
    $build->schedulingInfo->locker($$);
    $build->schedulingInfo->update;
});

die unless $build;

# Do the build.  If it throws an error, unlock the build so that it
# can be retried.
eval {
    doBuild $build;
};
if ($@) {
    warn $@;
    $db->txn_do(sub {
        $build->schedulingInfo->busy(0);
        $build->schedulingInfo->locker($$);
        $build->schedulingInfo->update;
    });
}
