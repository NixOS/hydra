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
    my ($project, $jobset, $jobName, $drvPath, $outPath, $usedInputs, $system) = @_;

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
            , system => $system
            });
        print "      build ID = ", $build->id, "\n";

        foreach my $inputName (keys %{$usedInputs}) {
            my $input = $usedInputs->{$inputName};
            $db->resultset('Buildinputs')->create(
                { buildid => $build->id
                , name => $inputName
                , type => $input->{type}
                , uri => $input->{uri}
                #, revision => $input->{orig}->revision
                #, tag => $input->{orig}->tag
                , value => $input->{value}
                , inputid => $input->{id}
                , path => ($input->{storePath} or "") # !!! temporary hack
                });
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
    my ($input, $alt, $inputInfo) = @_;
    my $type = $input->type;

    if ($type eq "path") {
        my $uri = $alt->uri;
        my $storePath = `nix-store --add "$uri"`
            or die "cannot copy path $uri to the Nix store";
        chomp $storePath;
        print "      copied to $storePath\n";
        $$inputInfo{$input->name} = {type => $type, uri => $uri, storePath => $storePath};
    }

    elsif ($type eq "string") {
        die unless defined $alt->value;
        $$inputInfo{$input->name} = {type => $type, value => $alt->value};
    }
    
    else {
        die "input `" . $input->type . "' has unknown type `$type'";
    }
}


sub checkJobSetInstance {
    my ($project, $jobset, $inputInfo) = @_;
    
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
                
                if (defined $inputInfo->{$argName}) {
                    # The argument name matches an input.
                    $$usedInputs{$argName} = $inputInfo->{$argName};
                    if (defined $inputInfo->{$argName}->{storePath}) {
                        # !!! escaping
                        $extraArgs .= " --arg $argName '{path = builtins.toPath " . $inputInfo->{$argName}->{storePath} . ";}'";
                    } elsif (defined $inputInfo->{$argName}->{value}) {
                        $extraArgs .= " --argstr $argName '" . $inputInfo->{$argName}->{value} . "'";
                    }
                }

                else {
                    (my $prevBuild) = $db->resultset('Builds')->search(
                        {project => $project->name, jobset => $jobset->name, attrname => $argName, buildStatus => 0},
                        {order_by => "timestamp DESC", rows => 1});

                    my $storePath;
                    
                    if (!defined $prevBuild) {
                        # !!! reschedule?
                        die "missing input `$argName'";
                    }
                    
                    # The argument name matches a previously built
                    # job in this jobset.  Pick the most recent
                    # build.  !!! refine the selection criteria:
                    # e.g., most recent successful build.
                    if (!isValidPath($prevBuild->outpath)) {
                        die "input path " . $prevBuild->outpath . " has been garbage-collected";
                    }
                    
                    $$usedInputs{$argName} =
                        { type => "build"
                        , storePath => $prevBuild->outpath
                        , id => $prevBuild->id
                        };

                    $extraArgs .= " --arg $argName '{path = builtins.toPath " . $prevBuild->outpath . ";}'";
                }
            }
        }

        # Instantiate the store derivation.
        print $extraArgs, "\n";
        my $drvPath = `nix-instantiate $nixExprPath --attr $jobName $extraArgs`
            or die "cannot evaluate the Nix expression containing the job definitions: $?";
        chomp $drvPath;

        # Call nix-env --xml to get info about this job (drvPath, outPath, meta attributes, ...).
        my $infoXml = `nix-env -f $nixExprPath --query --available "*" --attr-path --out-path --drv-path --meta --xml --system-filter "*" --attr $jobName $extraArgs`
            or die "cannot get information about the job: $?";

        my $info = XMLin($infoXml, KeyAttr => ['attrPath', 'name'])
            or die "cannot parse XML output";

        my $job = $info->{item};
        die if !defined $job || $job->{attrPath} ne $jobName;
        
        my $description = defined $job->{meta}->{description} ? $job->{meta}->{description}->{value} : "";
        die unless $job->{drvPath} eq $drvPath;
        my $outPath = $job->{outPath};

        buildJob($project, $jobset, $jobName, $drvPath, $outPath, $usedInputs, $job->{system});
    }
};


sub checkJobSetAlts {
    my ($project, $jobset, $inputs, $n, $inputInfo) = @_;

    if ($n >= scalar @{$inputs}) {
        checkJobSetInstance($project, $jobset, $inputInfo);
        return;
    }

    my $input = @{$inputs}[$n];

    foreach my $alt ($input->jobsetinputalts) {
        print "    INPUT ", $input->name, " (type ", $input->type, ") alt ", $alt->altnr, "\n";
        fetchInput($input, $alt, $inputInfo); # !!! caching
        checkJobSetAlts($project, $jobset, $inputs, $n + 1, $inputInfo);
    }
};

    
sub checkJobSet {
    my ($project, $jobset) = @_;
    my $inputInfo = {};
    my @jobsetinputs = $jobset->jobsetinputs;
    checkJobSetAlts($project, $jobset, \@jobsetinputs, 0, $inputInfo);
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
