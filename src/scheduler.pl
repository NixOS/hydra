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

        if ($outputCreated) {

            my $productnr = 0;

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

            if (-e "$outPath/nix-support/hydra-build-products") {
                open LIST, "$outPath/nix-support/hydra-build-products" or die;
                while (<LIST>) {
                    /^(\w+)\s+([\w-]+)\s+(\S+)$/ or die;
                    my $type = $1;
                    my $subtype = $2;
                    my $path = $3;
                    die unless -e $path;
                    $db->resultset('Buildproducts')->create(
                        { buildid => $build->id
                        , productnr => $productnr++
                        , type => $type
                        , subtype => $subtype
                        , path => $path
                        });
                }
                close LIST;
            } else {
                $db->resultset('Buildproducts')->create(
                    { buildid => $build->id
                    , productnr => $productnr++
                    , type => "nix-build"
                    , subtype => ""
                    , path => $outPath
                    });
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
        print "          copied to $storePath\n";
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


sub checkJob {
    my ($project, $jobset, $inputInfo, $nixExprPath, $jobName, $jobExpr, $extraArgs) = @_;
    
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
    die if !defined $job || $job->{attrPath} ne $jobName;
        
    my $description = defined $job->{meta}->{description} ? $job->{meta}->{description}->{value} : "";
    die unless $job->{drvPath} eq $drvPath;
    my $outPath = $job->{outPath};

    buildJob($project, $jobset, $jobName, $drvPath, $outPath, $inputInfo, $job->{system});
};


sub checkJobAlternatives {
    my ($project, $jobset, $inputInfo, $nixExprPath, $jobName, $jobExpr, $extraArgs, $argsNeeded, $n) = @_;

    if ($n >= scalar @{$argsNeeded}) {
        checkJob($project, $jobset, $inputInfo, $nixExprPath, $jobName, $jobExpr, $extraArgs);
        return;
    }

    my $argName = @{$argsNeeded}[$n];
    print "      finding alternatives for argument $argName\n";

    my ($input) = $jobset->jobsetinputs->search({name => $argName});

    my %newInputInfo = %{$inputInfo}; $inputInfo = \%newInputInfo; # clone

    if (defined $input) {
        
        foreach my $alt ($input->jobsetinputalts) {
            print "        INPUT ", $input->name, " (type ", $input->type, ") alt ", $alt->altnr, "\n";
            fetchInput($input, $alt, $inputInfo); # !!! caching
            my $newArgs = "";
            if (defined $inputInfo->{$argName}->{storePath}) {
                # !!! escaping
                $newArgs = " --arg $argName '{path = " . $inputInfo->{$argName}->{storePath} . ";}'";
            } elsif (defined $inputInfo->{$argName}->{value}) {
                $newArgs = " --argstr $argName '" . $inputInfo->{$argName}->{value} . "'";
            }
            checkJobAlternatives(
                $project, $jobset, $inputInfo, $nixExprPath,
                $jobName, $jobExpr, $extraArgs . $newArgs, $argsNeeded, $n + 1);
        }
    }

    else {

        (my $prevBuild) = $db->resultset('Builds')->search(
            {project => $project->name, jobset => $jobset->name, attrname => $argName, buildStatus => 0},
            {order_by => "timestamp DESC", rows => 1});

        if (!defined $prevBuild) {
            # !!! reschedule?
            die "missing input `$argName'";
        }

        # The argument name matches a previously built job in this
        # jobset.  Pick the most recent build.  !!! refine the
        # selection criteria: e.g., most recent successful build.
        if (!isValidPath($prevBuild->outpath)) {
            die "input path " . $prevBuild->outpath . " has been garbage-collected";
        }
                    
        $$inputInfo{$argName} =
            { type => "build"
            , storePath => $prevBuild->outpath
            , id => $prevBuild->id
            };

        checkJobAlternatives(
            $project, $jobset, $inputInfo, $nixExprPath,
            $jobName, $jobExpr,
            $extraArgs . " --arg $argName '{path = " . $prevBuild->outpath . ";}'",
            $argsNeeded, $n + 1);
    }
}

    
sub checkJobSet {
    my ($project, $jobset) = @_;
    my $inputInfo = {};

    # Fetch the input containing the Nix expression.
    (my $exprInput) = $jobset->jobsetinputs->search({name => $jobset->nixexprinput});
    die unless defined $exprInput;

    die "not supported yet" if scalar($exprInput->jobsetinputalts) != 1;

    fetchInput($exprInput, $exprInput->jobsetinputalts->first, $inputInfo);

    # Evaluate the Nix expression.
    my $nixExprPath = $inputInfo->{$jobset->nixexprinput}->{storePath} . "/" . $jobset->nixexprpath;

    print "    EVALUATING $nixExprPath\n";
 
    my $jobsXml = `nix-instantiate $nixExprPath --eval-only --strict --xml`
        or die "cannot evaluate the Nix expression containing the jobs: $?";

    my $jobs = XMLin($jobsXml,
                     ForceArray => [qw(value)],
                     KeyAttr => ['name'],
                     SuppressEmpty => '',
                     ValueAttr => [value => 'value'])
        or die "cannot parse XML output";

    die unless defined $jobs->{attrs};

    # Iterate over the attributes listed in the Nix expression and
    # perform the builds described by them.  If an attribute is a
    # function, then fill in the function arguments with the
    # (alternative) values supplied in the jobsetinputs table.
    foreach my $jobName (keys(%{$jobs->{attrs}->{attr}})) {
        print "    JOB $jobName\n";

        my @argsNeeded = ();
        
        my $jobExpr = $jobs->{attrs}->{attr}->{$jobName};

        # !!! fix the case where there is only 1 attr, XML::Simple fucks up as usual
        if (defined $jobExpr->{function}->{attrspat}) {
            foreach my $argName (keys(%{$jobExpr->{function}->{attrspat}->{attr}})) {
                print "      needs input $argName\n";
                push @argsNeeded, $argName;
            }            
        }

        checkJobAlternatives(
            $project, $jobset, {}, $nixExprPath,
            $jobName, $jobExpr, "", \@argsNeeded, 0);
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
