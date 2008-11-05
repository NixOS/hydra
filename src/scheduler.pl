#! @perl@ -w

use strict;
use XML::Simple;
use File::Basename;
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});


sub isValidPath {
    my $path = shift;
    return system("nix-store --check-validity $path 2> /dev/null") == 0;
}


sub buildJob {
    my ($project, $jobset, $jobName, $drvPath, $outPath, $usedInputs) = @_;

    if (scalar($db->resultset('Builds')->search({project => $project->name, jobset => $jobset->name, attrname => $jobName, outPath => $outPath})) > 0) {
        print "      already done\n";
        return;
    }

    my $isCachedBuild = 1;
    my $buildStatus = 0;
    my $startTime = 0;
    my $stopTime = 0;
    
    if (!isValidPath($outPath)) {
        $isCachedBuild = 0;

        $startTime = time();

        print "      BUILDING\n";

        my $res = system("nix-store --realise $drvPath");

        $stopTime = time();

        $buildStatus = $res == 0 ? 0 : 1;
    }

    $db->txn_do(sub {
        my $build = $db->resultset('Builds')->create(
            { timestamp => time()
            , project => $project->name
            , jobset => $jobset->name
            , attrname => $jobName
            , drvpath => $drvPath
            , outpath => $outPath
            , iscachedbuild => $isCachedBuild
            , buildstatus => $buildStatus
            , starttime => $startTime
            , stoptime => $stopTime
            });
        print "      build ID = ", $build->id, "\n";

        foreach my $inputName (keys %{$usedInputs}) {
            my $input = $usedInputs->{$inputName};
            if (defined $input->{orig}) {
                $db->resultset('Buildinputs')->create(
                    { buildid => $build->id
                    , name => $inputName
                    , type => $input->{orig}->type
                    , uri => $input->{orig}->uri
                    , revision => $input->{orig}->revision
                    , tag => $input->{orig}->tag
                    , path => $input->{storePath}
                    });
            } else {
                $db->resultset('Buildinputs')->create(
                    { buildid => $build->id
                    , name => $inputName
                    , type => "build"
                    , inputid => $input->{id}
                    , path => $input->{storePath}
                    });
            }
        }

        my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
        if (-e $logPath) {
            print "      LOG $logPath\n";
            $db->resultset('Buildlogs')->create(
                { buildid => $build->id
                , logphase => "full"
                , path => $logPath
                , type => "raw"
                });
        }

        if ($buildStatus == 0) {

            $db->resultset('Buildproducts')->create(
                { buildid => $build->id
                , type => "nix-build"
                , subtype => ""
                , path => $outPath
                });
            
            if (-e "$outPath/log") {
                foreach my $logPath (glob "$outPath/log/*") {
                    print "      LOG $logPath\n";
                    $db->resultset('Buildlogs')->create(
                        { buildid => $build->id
                        , logphase => basename($logPath)
                        , path => $logPath
                        , type => "raw"
                        });
                }
            }
        }
        
    });

}


sub fetchInput {
    my ($input, $inputInfo) = @_;
    my $type = $input->type;
    my $uri = $input->uri;

    if ($type eq "path") {
        my $storePath = `nix-store --add "$uri"`
            or die "cannot copy path $uri to the Nix store";
        chomp $storePath;
        print "      copied to $storePath\n";
        $$inputInfo{$input->name} = {orig => $input, storePath => $storePath};
    }

    else {
        die "input `" . $input->type . "' has unknown type `$type'";
    }
}


sub checkJobSet {
    my ($project, $jobset) = @_;

    my $inputInfo = {};

    foreach my $input ($jobset->jobsetinputs) {
        print "    INPUT ", $input->name, " (", $input->type, " ", $input->uri, ")\n";
        fetchInput($input, $inputInfo);
    }

    die unless defined $inputInfo->{$jobset->nixexprinput};

    my $nixExprPath = $inputInfo->{$jobset->nixexprinput}->{storePath} . "/" . $jobset->nixexprpath;

    print "    EVALUATING $nixExprPath\n";
 
    my $jobsXml = `nix-instantiate $nixExprPath --eval-only --strict --xml`
        or die "cannot evaluate the Nix expression containing the jobs: $?";

    #print "$jobsXml";
    
    my $jobs = XMLin($jobsXml,
                     ForceArray => [qw(value)],
                     KeyAttr => ['name'],
                     SuppressEmpty => '',
                     ValueAttr => [value => 'value'])
        or die "cannot parse XML output";

    die unless defined $jobs->{attrs};

    foreach my $jobName (keys(%{$jobs->{attrs}->{attr}})) {
        print "    JOB $jobName\n";

        my $jobExpr = $jobs->{attrs}->{attr}->{$jobName};

        my $extraArgs = "";

        my $usedInputs = {};

        # If the expression is a function, then look at its formal
        # arguments and see if we can supply them.
        if (defined $jobExpr->{function}->{attrspat}) {
            
            foreach my $argName (keys(%{$jobExpr->{function}->{attrspat}->{attr}})) {
                print "      needs input $argName\n";
                
                my $storePath;
                
                if (defined $inputInfo->{$argName}) {
                    # The argument name matches an input.
                    $storePath = $inputInfo->{$argName}->{storePath};
                    $$usedInputs{$argName} = $inputInfo->{$argName};
                }

                else {
                    (my $prevBuild) = $db->resultset('Builds')->search(
                        {project => $project->name, jobset => $jobset->name, attrname => $argName},
                        {order_by => "timestamp DESC", rows => 1});
                    
                    if (defined $prevBuild) {
                        # The argument name matches a previously built
                        # job in this jobset.  Pick the most recent
                        # build.  !!! refine the selection criteria:
                        # e.g., most recent successful build.
                        if (!isValidPath($prevBuild->outpath)) {
                            die "input path " . $prevBuild->outpath . " has been garbage-collected";
                        }
                        $storePath = $prevBuild->outpath;
                    } else {
                        # !!! reschedule?
                        die "missing input `$argName'";
                    }
                    $$usedInputs{$argName} =
                        { storePath => $storePath
                        , id => $prevBuild->id
                        };
                }
                
                $extraArgs .= " --arg $argName '{path = " . $storePath . ";}'";
            }
        }

        # Instantiate the store derivation.
        my $drvPath = `nix-instantiate $nixExprPath --attr $jobName $extraArgs`
            or die "cannot evaluate the Nix expression containing the job definitions: $?";
        chomp $drvPath;

        # Call nix-env --xml to get info about this job (drvPath, outPath, meta attributes, ...).
        my $infoXml = `nix-env -f $nixExprPath --query --available "*" --attr-path --out-path --drv-path --meta --xml --system-filter "*" --attr $jobName $extraArgs`
            or die "cannot get information about the job: $?";

        my $info = XMLin($infoXml, KeyAttr => ['attrPath', 'name'])
            or die "cannot parse XML output";

        my $job = $info->{item};
        die unless !defined $job || $job->{system} ne $jobName;
        
        my $description = defined $job->{meta}->{description} ? $job->{meta}->{description}->{value} : "";
        die unless $job->{drvPath} eq $drvPath;
        my $outPath = $job->{outPath};

        buildJob($project, $jobset, $jobName, $drvPath, $outPath, $usedInputs);
    }
}


sub checkJobs {

    foreach my $project ($db->resultset('Projects')->all) {
        print "PROJECT ", $project->name, "\n";
        foreach my $jobset ($project->jobsets->all) {
            print "  JOBSET ", $jobset->name, "\n";
            checkJobSet($project, $jobset);
        }
    }
    
}


checkJobs;
