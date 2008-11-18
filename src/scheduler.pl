#! @perl@ -w

use strict;
use XML::Simple;
use HydraFrontend::Schema;


my $db = HydraFrontend::Schema->connect("dbi:SQLite:dbname=hydra.sqlite", "", "", {});

$db->storage->dbh->do("PRAGMA synchronous = OFF;");


sub isValidPath {
    my $path = shift;
    return system("nix-store --check-validity $path 2> /dev/null") == 0;
}


sub getStorePathHash {
    my ($storePath) = @_;
    my $hash = `nix-store --query --hash $storePath`
        or die "cannot get hash of $storePath";
    chomp $hash;
    die unless $hash =~ /^sha256:(.*)$/;
    $hash = $1;
    $hash = `nix-hash --to-base16 --type sha256 $hash`
        or die "cannot convert hash";
    chomp $hash;
    return $hash;    
}


sub fetchInput {
    my ($input, $alt, $inputInfo) = @_;
    my $type = $input->type;

    if ($type eq "path") {
        my $uri = $alt->value;
        my $storePath = `nix-store --add "$uri"`
            or die "cannot copy path $uri to the Nix store";
        chomp $storePath;
        print "          copied to $storePath\n";
        
        $$inputInfo{$input->name} =
            { type => $type
            , uri => $uri
            , storePath => $storePath
            , sha256hash => getStorePathHash $storePath
            };
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

    my $info = XMLin($infoXml, ForceArray => 1, KeyAttr => ['attrPath', 'name'])
        or die "cannot parse XML output";

    my $job = $info->{item}->{$jobName};
    die if !defined $job;
        
    my $description = defined $job->{meta}->{description} ? $job->{meta}->{description}->{value} : "";
    die unless $job->{drvPath} eq $drvPath;
    my $outPath = $job->{outPath};

    $db->txn_do(sub {
        if (scalar($db->resultset('Builds')->search(
                { project => $project->name, jobset => $jobset->name
                , attrname => $jobName, outPath => $outPath })) > 0)
        {
            print "      already scheduled/done\n";
            return;
        }

        print "      adding to queue\n";
        
        my $build = $db->resultset('Builds')->create(
            { finished => 0
            , timestamp => time()
            , project => $project->name
            , jobset => $jobset->name
            , attrname => $jobName
            , description => $description
            , nixname => $job->{name}
            , drvpath => $drvPath
            , outpath => $outPath
            , system => $job->{system}
            });

        $db->resultset('Buildschedulinginfo')->create(
            { id => $build->id
            , priority => 0
            , busy => 0
            , locker => ""
            });

        foreach my $inputName (keys %{$inputInfo}) {
            my $input = $inputInfo->{$inputName};
            $db->resultset('Buildinputs')->create(
                { build => $build->id
                , name => $inputName
                , type => $input->{type}
                , uri => $input->{uri}
                #, revision => $input->{orig}->revision
                #, tag => $input->{orig}->tag
                , value => $input->{value}
                , dependency => $input->{id}
                , path => ($input->{storePath} or "") # !!! temporary hack
                , sha256hash => $input->{sha256hash}
                });
        }
    });
};


sub checkJobAlternatives {
    my ($project, $jobset, $inputInfo, $nixExprPath, $jobName, $jobExpr, $extraArgs, $argsNeeded, $n) = @_;

    if ($n >= scalar @{$argsNeeded}) {
        eval {
            checkJob($project, $jobset, $inputInfo, $nixExprPath, $jobName, $jobExpr, $extraArgs);
        };
        warn $@ if $@;
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
            {finished => 1, project => $project->name, jobset => $jobset->name, attrname => $argName, buildStatus => 0},
            {join => 'resultInfo', order_by => "timestamp DESC", rows => 1});

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
                     ForceArray => ['value', 'attr'],
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

        eval {
            checkJobAlternatives(
                $project, $jobset, {}, $nixExprPath,
                $jobName, $jobExpr, "", \@argsNeeded, 0);
        };
        warn $@ if $@;
    }
}


sub checkJobs {

    foreach my $project ($db->resultset('Projects')->search({enabled => 1})) {
        print "PROJECT ", $project->name, "\n";
        foreach my $jobset ($project->jobsets->all) {
            print "  JOBSET ", $jobset->name, "\n";
            eval {
                checkJobSet($project, $jobset);
            }; 
            warn $@ if $@;
       }
    }
    
}


while (1) {
    checkJobs;
    print "sleeping...\n";
    sleep 10;
}
