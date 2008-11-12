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

        # Run Nix to perform the build, and monitor the stderr output
        # to get notifications about specific build steps, the
        # associated log files, etc.
        my $cmd = "nix-store --keep-going --no-build-output " .
            "--log-type flat --print-build-trace --realise $drvPath 2>&1";

        my $buildStepNr = 1;
        
        open OUT, "$cmd |" or die;

        while (<OUT>) {
            unless (/^@\s+/) {
                print STDERR "$_";
                next;
            }
            
            if (/^@\s+build-started\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/) {
                $db->txn_do(sub {
                    $db->resultset('Buildsteps')->create(
                        { id => $build->id
                        , stepnr => $buildStepNr++
                        , type => 0 # = build
                        , drvpath => $1
                        , outpath => $2
                        , logfile => $4
                        , busy => 1
                        , starttime => time
                        });
                });
            }
            
            elsif (/^@\s+build-succeeded\s+(\S+)\s+(\S+)$/) {
                my $drvPath = $1;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('Buildsteps')->search(
                        {id => $build->id, type => 0, drvpath => $drvPath}, {});
                    die unless $step;
                    $step->busy(0);
                    $step->status(0);
                    $step->stoptime(time);
                    $step->update;
                });
            }

            elsif (/^@\s+build-failed\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/) {
                my $drvPath = $1;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('Buildsteps')->search(
                        {id => $build->id, type => 0, drvpath => $drvPath}, {});
                    if ($step) {
                        die unless $step;
                        $step->busy(0);
                        $step->status(1);
                        $step->errormsg($4);
                        $step->stoptime(time);
                        $step->update;
                    } else {
                        $db->resultset('Buildsteps')->create(
                            { id => $build->id
                            , stepnr => $buildStepNr++
                            , type => 0 # = build
                            , drvpath => $drvPath
                            , outpath => $2
                            , logfile => $4
                            , busy => 0
                            , status => 1
                            , starttime => time
                            , stoptime => time
                            , errormsg => $4
                            });
                    }
                });
            }

            elsif (/^@\s+substituter-started\s+(\S+)\s+(\S+)$/) {
                my $outPath = $1;
                $db->txn_do(sub {
                    $db->resultset('Buildsteps')->create(
                        { id => $build->id
                        , stepnr => $buildStepNr++
                        , type => 1 # = substitution
                        , outpath => $1
                        , busy => 1
                        , starttime => time
                        });
                });
            }

            elsif (/^@\s+substituter-succeeded\s+(\S+)$/) {
                my $outPath = $1;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('Buildsteps')->search(
                        {id => $build->id, type => 1, outpath => $outPath}, {});
                    die unless $step;
                    $step->busy(0);
                    $step->status(0);
                    $step->stoptime(time);
                    $step->update;
                });
            }

            elsif (/^@\s+substituter-failed\s+(\S+)\s+(\S+)\s+(\S+)$/) {
                my $outPath = $1;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('Buildsteps')->search(
                        {id => $build->id, type => 1, outpath => $outPath}, {});
                    die unless $step;
                    $step->busy(0);
                    $step->status(1);
                    $step->errormsg($3);
                    $step->stoptime(time);
                    $step->update;
                });
            }

            else {
                print STDERR "unknown Nix trace message: $_";
            }
        }
        
        close OUT;

        my $res = $?;

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
            print STDERR "found log $logPath\n";
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
                    print STDERR "found log $logPath\n";
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
print STDERR "performing build $buildId\n";

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
