#! /var/run/current-system/sw/bin/perl -w

use strict;
use File::Basename;
use File::stat;
use Hydra::Schema;
use Hydra::Helper::Nix;


my $db = openHydraDB;


sub doBuild {
    my ($build) = @_;

    my $drvPath = $build->drvpath;
    my $outPath = $build->outpath;

    my $isCachedBuild = 1;
    my $outputCreated = 1; # i.e., the Nix build succeeded (but it could be a positive failure)
    my $startTime = 0;
    my $stopTime = 0;

    my $buildStatus = 0; # = succeeded

    my $errormsg = undef;

    my $failedDepBuild;
    my $failedDepStepNr;
    
    registerRoot $outPath;
    
    if (!isValidPath($outPath)) {
        $isCachedBuild = 0;

        # Check whether a dependency of this build has previously
        # failed.  If so, don't even bother to build, since it will
        # fail anyway.  !!! Once Nix has negative caching, this code
        # can go.

        my @drvDeps = split '\n', `nix-store --query --requisites --include-outputs $drvPath`;
        die "cannot query dependencies of `$drvPath': $?" if $? != 0;

        @drvDeps = grep { $_ =~ /.drv$/ } @drvDeps;

        my @drvOutputs = split '\n', `nix-store --query --outputs @drvDeps`;
        die "cannot query outputs of the dependencies of `$drvPath': $?" if $? != 0;

        foreach my $dep (@drvOutputs) {
            # !!! This checks more than it has to, namely
            # build-time-only dependencies of dependencies (which
            # don't need to be built).  However, it shouldn't matter:
            # if the dependency was built, then presumably *its*
            # dependencies were built as well.
            # !!! should disregard fixed-output derivations (?)
            if (!isValidPath($dep)) {
                my ($step) = $db->resultset('BuildSteps')->search(
                    {outPath => $dep}, {rows => 1, order_by => "stopTime DESC"});
                if (defined $step && $step->status != 0) {
                    $buildStatus = 5;
                    $failedDepBuild = $step->id->id;
                    $failedDepStepNr = $step->stepnr;
                    goto done;
                }
            }
        }
        
        # Do the build.
        $startTime = time();

        my $thisBuildFailed = 0;
        my $someBuildFailed = 0;
        
        # Run Nix to perform the build, and monitor the stderr output
        # to get notifications about specific build steps, the
        # associated log files, etc.
        my $cmd = "nix-store --max-silent-time 1800 --keep-going --no-build-output " .
            "--log-type flat --print-build-trace --realise $drvPath 2>&1";

        my $buildStepNr = 1;
        
        open OUT, "$cmd |" or die;

        while (<OUT>) {
            $errormsg .= $_;
            
            unless (/^@\s+/) {
                print STDERR "$_";
                next;
            }
            
            if (/^@\s+build-started\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/) {
                $db->txn_do(sub {
                    $db->resultset('BuildSteps')->create(
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
                    (my $step) = $db->resultset('BuildSteps')->search(
                        {id => $build->id, type => 0, drvpath => $drvPath}, {});
                    die unless $step;
                    $step->update({busy => 0, status => 0, time => 0});
                });
            }

            elsif (/^@\s+build-failed\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/) {
                my $drvPathStep = $1;
                $someBuildFailed = 1;
                $thisBuildFailed = 1 if $drvPath eq $drvPathStep;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('BuildSteps')->search(
                        {id => $build->id, type => 0, drvpath => $drvPathStep}, {});
                    if ($step) {
                        $step->update({busy => 0, status => 1, errormsg => $4, stoptime => time});
                    } else {
                        $db->resultset('BuildSteps')->create(
                            { id => $build->id
                            , stepnr => $buildStepNr++
                            , type => 0 # = build
                            , drvpath => $drvPathStep
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
                    $db->resultset('BuildSteps')->create(
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
                    (my $step) = $db->resultset('BuildSteps')->search(
                        {id => $build->id, type => 1, outpath => $outPath}, {});
                    die unless $step;
                    $step->update({busy => 0, status => 0, stoptime => time});
                });
            }

            elsif (/^@\s+substituter-failed\s+(\S+)\s+(\S+)\s+(\S+)$/) {
                my $outPath = $1;
                $db->txn_do(sub {
                    (my $step) = $db->resultset('BuildSteps')->search(
                        {id => $build->id, type => 1, outpath => $outPath}, {});
                    die unless $step;
                    $step->update({busy => 0, status => 1, errormsg => $3, stoptime => time});
                });
            }

            else {
                print STDERR "unknown Nix trace message: $_";
            }
        }
        
        close OUT;

        my $res = $?;

        $stopTime = time();

        if ($res != 0) {
            if ($thisBuildFailed) { $buildStatus = 1; }
            elsif ($someBuildFailed) { $buildStatus = 2; }
            else { $buildStatus = 3; }
        }

        # Only store the output of running Nix if we have a miscellaneous error.
        $errormsg = undef unless $buildStatus == 3;
    }

  done:

    $db->txn_do(sub {
        $build->update({finished => 1, timestamp => time});

        my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
        $logPath = undef unless -e $logPath;

        my $releaseName;
        if (-e "$outPath/nix-support/hydra-release-name") {
            open FILE, "$outPath/nix-support/hydra-release-name" or die;
            $releaseName = <FILE>;
            chomp $releaseName;
            close FILE;
        }
        
        $db->resultset('BuildResultInfo')->create(
            { id => $build->id
            , iscachedbuild => $isCachedBuild
            , buildstatus => $buildStatus
            , starttime => $startTime
            , stoptime => $stopTime
            , logfile => $logPath
            , errormsg => $errormsg
            , releasename => $releaseName
            , faileddepbuild => $failedDepBuild
            , faileddepstepnr => $failedDepStepNr
            });

        if ($buildStatus == 0) {

            my $productnr = 1;

            if (-e "$outPath/nix-support/hydra-build-products") {
                open LIST, "$outPath/nix-support/hydra-build-products" or die;
                while (<LIST>) {
                    /^([\w\-]+)\s+([\w\-]+)\s+(\S+)(\s+(\S+))?$/ or next;
                    my $type = $1;
                    my $subtype = $2 eq "none" ? "" : $2;
                    my $path = $3;
                    my $defaultPath = $5;
                    next unless -e $path;

                    my $fileSize, my $sha1, my $sha256;

                    # !!! validate $path, $defaultPath

                    if (-f $path) {
                        my $st = stat($path) or die "cannot stat $path: $!";
                        $fileSize = $st->size;
                        
                        $sha1 = `nix-hash --flat --type sha1 $path`
                            or die "cannot hash $path: $?";;
                        chomp $sha1;
                    
                        $sha256 = `nix-hash --flat --type sha256 $path`
                            or die "cannot hash $path: $?";;
                        chomp $sha256;
                    }

                    my $name = $path eq $outPath ? "" : basename $path;
                    
                    $db->resultset('BuildProducts')->create(
                        { build => $build->id
                        , productnr => $productnr++
                        , type => $type
                        , subtype => $subtype
                        , path => $path
                        , filesize => $fileSize
                        , sha1hash => $sha1
                        , sha256hash => $sha256
                        , name => $name
                        , defaultpath => $defaultPath
                        });
                }
                close LIST;
            }

            else {
                $db->resultset('BuildProducts')->create(
                    { build => $build->id
                    , productnr => $productnr++
                    , type => "nix-build"
                    , subtype => ""
                    , path => $outPath
                    , name => $build->nixname
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
    $build = $db->resultset('Builds')->find($buildId);
    die "build $buildId doesn't exist" unless defined $build;
    die "build $buildId already done" if defined $build->resultInfo;
    if ($build->schedulingInfo->busy != 0 && $build->schedulingInfo->locker != getppid) {
        die "build $buildId is already being built";
    }
    $build->schedulingInfo->update({busy => 1, locker => $$});
    $build->buildsteps->delete_all;
    $build->buildproducts->delete_all;
});

die unless $build;

# Do the build.  If it throws an error, unlock the build so that it
# can be retried.
eval {
    doBuild $build;
    print "done\n";
};
if ($@) {
    warn $@;
    $db->txn_do(sub {
        $build->schedulingInfo->update({busy => 0, locker => $$});
    });
}
