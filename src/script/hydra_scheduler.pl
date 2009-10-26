#! /var/run/current-system/sw/bin/perl -w

use strict;
use feature 'switch';
use XML::Simple;
use Hydra::Schema;
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;
use IPC::Run;


STDOUT->autoflush();

my $db = openHydraDB;


sub captureStdoutStderr {
    my $stdin = ""; my $stdout; my $stderr;
    my $res = IPC::Run::run(\@_, \$stdin, \$stdout, \$stderr);
    return ($res, $stdout, $stderr);
}

    
sub fetchInputs {
    my ($project, $jobset, $inputInfo) = @_;
    foreach my $input ($jobset->jobsetinputs->all) {
        foreach my $alt ($input->jobsetinputalts->all) {
            my $info = fetchInput($db, $project, $jobset, $input->name, $input->type, $alt->value);
            push @{$$inputInfo{$input->name}}, $info if defined $info;
        }
    }
}


# Check whether to add the build described by $buildInfo.
sub checkBuild {
    my ($project, $jobset, $inputInfo, $nixExprInput, $buildInfo, $currentBuilds) = @_;

    my $jobName = $buildInfo->{jobName};
    my $drvPath = $buildInfo->{drvPath};
    my $outPath = $buildInfo->{outPath};

    my $priority = 100;
    $priority = int($buildInfo->{schedulingPriority})
        if $buildInfo->{schedulingPriority} =~ /^\d+$/;

    txn_do($db, sub {
        # Update the last evaluation time in the database.
        my $job = $jobset->jobs->update_or_create(
            { name => $jobName
            , lastevaltime => time
            });

        $job->update({firstevaltime => time})
            unless defined $job->firstevaltime;

        # Don't add a build that has already been scheduled for this
        # job, or has been built but is still a "current" build for
        # this job.  Note that this means that if the sources of a job
        # are changed from A to B and then reverted to A, three builds
        # will be performed (though the last one will probably use the
        # cached result from the first).  This ensures that the builds
        # with the highest ID will always be the ones that we want in
        # the channels.
        # !!! Checking $outPath doesn't take meta-attributes into
        # account.  For instance, do we want a new build to be
        # scheduled if the meta.maintainers field is changed?
        my @previousBuilds = $job->builds->search({outPath => $outPath, isCurrent => 1});
        if (scalar(@previousBuilds) > 0) {
            print "already scheduled/built\n";
            $currentBuilds->{$_->id} = 1 foreach @previousBuilds;
            return;
        }
        
        # Nope, so add it.
        my $build = $job->builds->create(
            { finished => 0
            , timestamp => time()
            , description => $buildInfo->{description}
            , longdescription => $buildInfo->{longDescription}
            , license => $buildInfo->{license}
            , homepage => $buildInfo->{homepage}
            , maintainers => $buildInfo->{maintainers}
            , nixname => $buildInfo->{nixName}
            , drvpath => $drvPath
            , outpath => $outPath
            , system => $buildInfo->{system}
            , iscurrent => 1
            , nixexprinput => $jobset->nixexprinput
            , nixexprpath => $jobset->nixexprpath
            });

        print "added to queue as build ", $build->id, "\n";
        
        $currentBuilds->{$build->id} = 1;
        
        $build->create_related('buildschedulinginfo',
            { priority => $priority
            , busy => 0
            , locker => ""
            });

        my %inputs;
        $inputs{$jobset->nixexprinput} = $nixExprInput;
        foreach my $arg (@{$buildInfo->{arg}}) {
            $inputs{$arg->{name}} = $inputInfo->{$arg->{name}}->[$arg->{altnr}]
                || die "invalid input";
        }

        foreach my $name (keys %inputs) {
            my $input = $inputs{$name};
            $build->buildinputs_builds->create(
                { name => $name
                , type => $input->{type}
                , uri => $input->{uri}
                , revision => $input->{revision}
                , value => $input->{value}
                , dependency => $input->{id}
                , path => $input->{storePath} || "" # !!! temporary hack
                , sha256hash => $input->{sha256hash}
                });
        }
    });
};


sub setJobsetError {
    my ($jobset, $errorMsg) = @_;
    eval {
        txn_do($db, sub {
            $jobset->update({errormsg => $errorMsg, errortime => time});
        });
    };
}


sub inputsToArgs {
    my ($inputInfo) = @_;
    my @res = ();

    foreach my $input (keys %{$inputInfo}) {
        foreach my $alt (@{$inputInfo->{$input}}) {
            given ($alt->{type}) {
                when ("string") {
                    push @res, "--argstr", $input, $alt->{value};
                }
                when ("boolean") {
                    push @res, "--arg", $input, $alt->{value};
                }
                when (["svn", "path", "build"]) {
                    push @res, "--arg", $input, (
                        "{ outPath = builtins.storePath " . $alt->{storePath} . "" .
                        (defined $alt->{revision} ? "; rev = \"" . $alt->{revision} . "\"" : "") .
                        (defined $alt->{version} ? "; version = \"" . $alt->{version} . "\"" : "") .
                        ";}"
                    );
                }
            }
        }
    }

    return @res;
}


sub permute {
    my @list = @_;
    for (my $n = scalar @list - 1; $n > 0; $n--) {
        my $k = int(rand($n + 1)); # 0 <= $k <= $n 
        @list[$n, $k] = @list[$k, $n];
    }
    return @list;
}


sub checkJobset {
    my ($project, $jobset) = @_;
    my $inputInfo = {};
    
    # Fetch all values for all inputs.
    fetchInputs($project, $jobset, $inputInfo);

    # Evaluate the job expression.
    my $nixExprInput = $inputInfo->{$jobset->nixexprinput}->[0]
        or die "cannot find the input containing the job expression";
    die "multiple alternatives for the input containing the Nix expression are not supported"
        if scalar @{$inputInfo->{$jobset->nixexprinput}} != 1;
    my $nixExprPath = $nixExprInput->{storePath} . "/" . $jobset->nixexprpath;

    (my $res, my $jobsXml, my $stderr) = captureStdoutStderr(
        "hydra_eval_jobs", $nixExprPath, "--gc-roots-dir", getGCRootsDir,
        inputsToArgs($inputInfo));
    die "cannot evaluate the Nix expression containing the jobs:\n$stderr" unless $res;

    print STDERR "$stderr";

    my $jobs = XMLin($jobsXml,
                     ForceArray => ['error', 'job', 'arg'],
                     KeyAttr => [],
                     SuppressEmpty => '')
        or die "cannot parse XML output";

    # Schedule each successfully evaluated job.
    my %currentBuilds;
    foreach my $job (permute @{$jobs->{job}}) {
        next if $job->{jobName} eq "";
        print "considering job " . $job->{jobName} . "\n";
        checkBuild($project, $jobset, $inputInfo, $nixExprInput, $job, \%currentBuilds);
    }

    txn_do($db, sub {
        
        # Update the last checked times and error messages for each
        # job.
        my %failedJobNames;
        push @{$failedJobNames{$_->{location}}}, $_->{msg} foreach @{$jobs->{error}};

        $jobset->update({lastcheckedtime => time});
        
        foreach my $job ($jobset->jobs->all) {
            if ($failedJobNames{$job->name}) {
                $job->update({errormsg => join '\n', @{$failedJobNames{$job->name}}});
            } else {
                $job->update({errormsg => undef});
            }
        }

        # Clear the "current" flag on all builds that are no longer
        # current.
        foreach my $build ($jobset->builds->search({iscurrent => 1})) {
            $build->update({iscurrent => 0}) unless $currentBuilds{$build->id};
        }
        
    });
       
    # Store the errors messages for jobs that failed to evaluate.
    my $msg = "";
    foreach my $error (@{$jobs->{error}}) {
        my $bindings = "";
        foreach my $arg (@{$error->{arg}}) {
            my $input = $inputInfo->{$arg->{name}}->[$arg->{altnr}] or die "invalid input";
            $bindings .= ", " if $bindings ne "";
            $bindings .= $arg->{name} . " = ";
            given ($input->{type}) {
                when ("string") { $bindings .= "\"" . $input->{value} . "\""; }
                when ("boolean") { $bindings .= $input->{value}; }
                default { $bindings .= "..."; }
            }
        }
        $msg .= "at `" . $error->{location} . "' [$bindings]:\n" . $error->{msg} . "\n\n";
    }
    setJobsetError($jobset, $msg);
}


sub checkJobsetWrapped {
    my ($project, $jobset) = @_;
    
    print "considering jobset ", $jobset->name, " in ", $project->name, "\n";
    
    eval {
        checkJobset($project, $jobset);
    };
    
    if ($@) {
        my $msg = $@;
        print "error evaluating jobset ", $jobset->name, ": $msg";
        txn_do($db, sub {
            $jobset->update({lastcheckedtime => time});
            setJobsetError($jobset, $msg);
        });
    }
}


sub checkProjects {
    foreach my $project ($db->resultset('Projects')->search({enabled => 1})) {
        print "considering project ", $project->name, "\n";
        checkJobsetWrapped($project, $_)
            foreach $project->jobsets->search({enabled => 1});
    }
}


# For testing: evaluate a single jobset, then exit.
if (scalar @ARGV == 2) {
    my $projectName = $ARGV[0];
    my $jobsetName = $ARGV[1];
    my $jobset = $db->resultset('Jobsets')->find($projectName, $jobsetName) or die;
    checkJobsetWrapped($jobset->project, $jobset);
    exit 0;
}


while (1) {
    eval {
        checkProjects;
    };
    if ($@) { print "$@"; }
    print "sleeping...\n";
    sleep 30;
}
