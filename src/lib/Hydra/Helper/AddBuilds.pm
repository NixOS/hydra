package Hydra::Helper::AddBuilds;

use strict;
use feature 'switch';
use XML::Simple;
use IPC::Run;
use Nix::Store;
use Nix::Config;
use Hydra::Model::DB;
use Hydra::Helper::Nix;
use Digest::SHA qw(sha256_hex);
use File::Basename;
use File::stat;
use File::Path;
use File::Temp;
use File::Spec;
use File::Slurp;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    fetchInput evalJobs checkBuild inputsToArgs
    getReleaseName addBuildProducts restartBuild
    getPrevJobsetEval
);


sub getReleaseName {
    my ($outPath) = @_;
    return undef unless -f "$outPath/nix-support/hydra-release-name";
    my $releaseName = read_file("$outPath/nix-support/hydra-release-name");
    chomp $releaseName;
    return $releaseName;
}


sub parseJobName {
    # Parse a job specification of the form `<project>:<jobset>:<job>
    # [attrs]'.  The project, jobset and attrs may be omitted.  The
    # attrs have the form `name = "value"'.
    my ($s) = @_;
    our $key;
    our %attrs = ();
    # hm, maybe I should stop programming Perl before it's too late...
    $s =~ / ^ (?: (?: ([\w\-]+) : )? ([\w\-]+) : )? ([\w\-\.]+) \s*
            (\[ \s* (
              ([\w]+) (?{ $key = $^N; }) \s* = \s* \"
              ([\w\-]+) (?{ $attrs{$key} = $^N; }) \"
            \s* )* \])? $
          /x
        or die "invalid job specifier `$s'";
    return ($1, $2, $3, \%attrs);
}


sub attrsToSQL {
    my ($attrs, $id) = @_;

    my $query = "1 = 1";

    foreach my $name (keys %{$attrs}) {
        my $value = $attrs->{$name};
        $name =~ /^[\w\-]+$/ or die;
        $value =~ /^[\w\-]+$/ or die;
        # !!! Yes, this is horribly injection-prone... (though
        # name/value are filtered above).  Should use SQL::Abstract,
        # but it can't deal with subqueries.  At least we should use
        # placeholders.
        $query .= " and exists (select 1 from buildinputs where build = $id and name = '$name' and value = '$value')";
    }

    return $query;
}


sub fetchInputBuild {
    my ($db, $project, $jobset, $name, $value) = @_;

    my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
    $projectName ||= $project->name;
    $jobsetName ||= $jobset->name;

    # Pick the most recent successful build of the specified job.
    (my $prevBuild) = $db->resultset('Builds')->search(
        { finished => 1, project => $projectName, jobset => $jobsetName
        , job => $jobName, buildStatus => 0 },
        { order_by => "me.id DESC", rows => 1
        , where => \ attrsToSQL($attrs, "me.id") });

    if (!defined $prevBuild || !isValidPath(getMainOutput($prevBuild)->path)) {
        print STDERR "input `", $name, "': no previous build available\n";
        return undef;
    }

    #print STDERR "input `", $name, "': using build ", $prevBuild->id, "\n";

    my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
    my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

    my $relName = ($prevBuild->releasename or $prevBuild->nixname);
    my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;

    return
        { storePath => getMainOutput($prevBuild)->path
        , id => $prevBuild->id
        , version => $version
        };
}


sub fetchInputSystemBuild {
    my ($db, $project, $jobset, $name, $value) = @_;

    my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
    $projectName ||= $project->name;
    $jobsetName ||= $jobset->name;

    my @latestBuilds = $db->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$projectName, $jobsetName, $jobName]});

    my @validBuilds = ();
    foreach my $build (@latestBuilds) {
        push(@validBuilds, $build) if isValidPath(getMainOutput($build)->path);
    }

    if (scalar(@validBuilds) == 0) {
        print STDERR "input `", $name, "': no previous build available\n";
        return ();
    }

    my @inputs = ();

    foreach my $prevBuild (@validBuilds) {
        my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
        my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

        my $relName = ($prevBuild->releasename or $prevBuild->nixname);
        my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;

        my $input =
            { storePath => getMainOutput($prevBuild)->path
            , id => $prevBuild->id
            , version => $version
            , system => $prevBuild->system
            };
        push(@inputs, $input);
    }

    return @inputs;
}


sub fetchInput {
    my ($plugins, $db, $project, $jobset, $name, $type, $value) = @_;
    my @inputs;

    if ($type eq "build") {
        @inputs = fetchInputBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "sysbuild") {
        @inputs = fetchInputSystemBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "string") {
        die unless defined $value;
        @inputs = { value => $value };
    }
    elsif ($type eq "boolean") {
        die unless defined $value && ($value eq "true" || $value eq "false");
        @inputs = { value => $value };
    }
    else {
        my $found = 0;
        foreach my $plugin (@{$plugins}) {
            @inputs = $plugin->fetchInput($type, $name, $value);
            if (defined $inputs[0]) {
                $found = 1;
                last;
            }
        }
        die "input `$name' has unknown type `$type'." unless $found;
    }

    $_->{type} = $type foreach @inputs;

    return @inputs;
}


sub booleanToString {
    my ($exprType, $value) = @_;
    my $result;
    if ($exprType eq "guile") {
        if ($value eq "true") {
            $result = "#t";
        } else {
            $result = "#f";
        }
        $result = $value;
    } else {
        $result = $value;
    }
    return $result;
}


sub buildInputToString {
    my ($exprType, $input) = @_;
    my $result;
    if ($exprType eq "guile") {
        $result = "'((file-name . \"" . ${input}->{storePath} . "\")" .
            (defined $input->{revision} ? "(revision . \"" . $input->{revision} . "\")" : "") .
            (defined $input->{revCount} ? "(revision-count . " . $input->{revCount} . ")" : "") .
            (defined $input->{gitTag} ? "(git-tag . \"" . $input->{gitTag} . "\")" : "") .
            (defined $input->{shortRev} ? "(short-revision . \"" . $input->{shortRev} . "\")" : "") .
            (defined $input->{version} ? "(version . \"" . $input->{version} . "\")" : "") .
            ")";
    } else {
        $result = "{ outPath = builtins.storePath " . $input->{storePath} . "" .
            (defined $input->{revNumber} ? "; rev = " . $input->{revNumber} . "" : "") .
            (defined $input->{revision} ? "; rev = \"" . $input->{revision} . "\"" : "") .
            (defined $input->{revCount} ? "; revCount = " . $input->{revCount} . "" : "") .
            (defined $input->{gitTag} ? "; gitTag = \"" . $input->{gitTag} . "\"" : "") .
            (defined $input->{shortRev} ? "; shortRev = \"" . $input->{shortRev} . "\"" : "") .
            (defined $input->{version} ? "; version = \"" . $input->{version} . "\"" : "") .
            ";}";
    }
    return $result;
}


sub inputsToArgs {
    my ($inputInfo, $exprType) = @_;
    my @res = ();

    foreach my $input (keys %{$inputInfo}) {
        push @res, "-I", "$input=$inputInfo->{$input}->[0]->{storePath}"
            if scalar @{$inputInfo->{$input}} == 1
               && defined $inputInfo->{$input}->[0]->{storePath};
        foreach my $alt (@{$inputInfo->{$input}}) {
            given ($alt->{type}) {
                when ("string") {
                    push @res, "--argstr", $input, $alt->{value};
                }
                when ("boolean") {
                    push @res, "--arg", $input, booleanToString($exprType, $alt->{value});
                }
                default {
                    push @res, "--arg", $input, buildInputToString($exprType, $alt);
                }
            }
        }
    }

    return @res;
}


sub evalJobs {
    my ($inputInfo, $exprType, $nixExprInputName, $nixExprPath) = @_;

    my $nixExprInput = $inputInfo->{$nixExprInputName}->[0]
        or die "cannot find the input containing the job expression.\n";
    die "multiple alternatives for the input containing the Nix expression are not supported.\n"
        if scalar @{$inputInfo->{$nixExprInputName}} != 1;
    my $nixExprFullPath = $nixExprInput->{storePath} . "/" . $nixExprPath;

    my $evaluator = ($exprType eq "guile") ? "hydra-eval-guile-jobs" : "hydra-eval-jobs";
    print STDERR "evaluator ${evaluator}\n";

    (my $res, my $jobsXml, my $stderr) = captureStdoutStderr(10800,
        $evaluator, $nixExprFullPath, "--gc-roots-dir", getGCRootsDir, "-j", 1, inputsToArgs($inputInfo, $exprType));
    if ($res) {
        die "$evaluator returned " . ($res & 127 ? "signal $res" : "exit code " . ($res >> 8))
            . ":\n" . ($stderr ? $stderr : "(no output)\n");
    }

    print STDERR "$stderr";

    my $jobs = XMLin(
        $jobsXml,
        ForceArray => ['error', 'job', 'arg', 'output'],
        KeyAttr => { output => "+name" },
        SuppressEmpty => '')
        or die "cannot parse XML output";

    my @filteredJobs = ();
    foreach my $job (@{$jobs->{job}}) {
        my $validJob = 1;
        foreach my $arg (@{$job->{arg}}) {
            my $input = $inputInfo->{$arg->{name}}->[$arg->{altnr}];
            if ($input->{type} eq "sysbuild" && $input->{system} ne $job->{system}) {
                $validJob = 0;
            }
        }
        if ($validJob) {
            push(@filteredJobs, $job);
        }
    }
    $jobs->{job} = \@filteredJobs;

    return ($jobs, $nixExprInput);
}


sub addBuildProducts {
    my ($db, $build) = @_;

    my $productnr = 1;
    my $explicitProducts = 0;
    my $storeDir = $Nix::Config::storeDir . "/";

    foreach my $output ($build->buildoutputs->all) {
        my $outPath = $output->path;
        if (-e "$outPath/nix-support/hydra-build-products") {
            $explicitProducts = 1;

            open LIST, "$outPath/nix-support/hydra-build-products" or die;
            while (<LIST>) {
                /^([\w\-]+)\s+([\w\-]+)\s+("[^"]*"|\S+)(\s+(\S+))?$/ or next;
                my $type = $1;
                my $subtype = $2 eq "none" ? "" : $2;
                my $path = substr($3, 0, 1) eq "\"" ? substr($3, 1, -1) : $3;
                my $defaultPath = $5;

                # Ensure that the path exists and points into the Nix store.
                next unless File::Spec->file_name_is_absolute($path);
                $path = pathIsInsidePrefix($path, $Nix::Config::storeDir);
                next unless defined $path;
                next unless -e $path;

                # FIXME: check that the path is in the input closure
                # of the build?

                my $fileSize, my $sha1, my $sha256;

                if (-f $path) {
                    my $st = stat($path) or die "cannot stat $path: $!";
                    $fileSize = $st->size;
                    $sha1 = hashFile("sha1", 0, $path);
                    $sha256 = hashFile("sha256", 0, $path);
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
    }

    return if $explicitProducts;

    foreach my $output ($build->buildoutputs->all) {
        my $outPath = $output->path;
        next unless -d $outPath;
        $db->resultset('BuildProducts')->create(
            { build => $build->id
            , productnr => $productnr++
            , type => "nix-build"
            , subtype => $output->name eq "out" ? "" : $output->name
            , path => $outPath
            , name => $build->nixname
            });
    }
}


# Return the most recent evaluation of the given jobset (that
# optionally had new builds), or undefined if no such evaluation
# exists.
sub getPrevJobsetEval {
    my ($db, $jobset, $hasNewBuilds) = @_;
    my ($prevEval) = $jobset->jobsetevals(
        ($hasNewBuilds ? { hasnewbuilds => 1 } : { }),
        { order_by => "id DESC", rows => 1 });
    return $prevEval;
}


# Check whether to add the build described by $buildInfo.
sub checkBuild {
    my ($db, $project, $jobset, $inputInfo, $nixExprInput, $buildInfo, $buildIds, $prevEval, $jobOutPathMap) = @_;

    my @outputNames = sort keys %{$buildInfo->{output}};
    die unless scalar @outputNames;

    # In various checks we can use an arbitrary output (the first)
    # rather than all outputs, since if one output is the same, the
    # others will be as well.
    my $firstOutputName = $outputNames[0];
    my $firstOutputPath = $buildInfo->{output}->{$firstOutputName}->{path};

    my $jobName = $buildInfo->{jobName} or die;
    my $drvPath = $buildInfo->{drvPath} or die;

    my $priority = 100;
    $priority = int($buildInfo->{schedulingPriority})
        if $buildInfo->{schedulingPriority} =~ /^\d+$/;

    my $build;

    txn_do($db, sub {
        my $job = $jobset->jobs->update_or_create(
            { name => $jobName
            });

        # Don't add a build that has already been scheduled for this
        # job, or has been built but is still a "current" build for
        # this job.  Note that this means that if the sources of a job
        # are changed from A to B and then reverted to A, three builds
        # will be performed (though the last one will probably use the
        # cached result from the first).  This ensures that the builds
        # with the highest ID will always be the ones that we want in
        # the channels.  FIXME: Checking the output paths doesn't take
        # meta-attributes into account.  For instance, do we want a
        # new build to be scheduled if the meta.maintainers field is
        # changed?
        if (defined $prevEval) {
            # Only check one output: if it's the same, the other will be as well.
            my $firstOutput = $outputNames[0];
            my ($prevBuild) = $prevEval->builds->search(
                # The "project" and "jobset" constraints are
                # semantically unnecessary (because they're implied by
                # the eval), but they give a factor 1000 speedup on
                # the Nixpkgs jobset with PostgreSQL.
                { project => $project->name, jobset => $jobset->name, job => $job->name,
                  name => $firstOutputName, path => $firstOutputPath },
                { rows => 1, columns => ['id'], join => ['buildoutputs'] });
            if (defined $prevBuild) {
                print STDERR "    already scheduled/built as build ", $prevBuild->id, "\n";
                $buildIds->{$prevBuild->id} = 0;
                return;
            }
        }

        # Prevent multiple builds with the same (job, outPath) from
        # being added.
        my $prev = $$jobOutPathMap{$job->name . "\t" . $firstOutputPath};
        if (defined $prev) {
            print STDERR "    already scheduled as build ", $prev, "\n";
            return;
        }

        my $time = time();

        # Are the outputs already in the Nix store?  Then add a cached
        # build.
        my %extraFlags;
        my $allValid = 1;
        my $buildStatus;
        my $releaseName;
        foreach my $name (@outputNames) {
            my $path = $buildInfo->{output}->{$name}->{path};
            if (isValidPath($path)) {
                if (-f "$path/nix-support/failed") {
                    $buildStatus = 6;
                } else {
                    $buildStatus //= 0;
                }
                $releaseName //= getReleaseName($path);
            } else {
                $allValid = 0;
                last;
            }
        }

        if ($allValid) {
            %extraFlags =
                ( finished => 1
                , iscachedbuild => 1
                , buildstatus => $buildStatus
                , starttime => $time
                , stoptime => $time
                , releasename => $releaseName
                );
        } else {
            %extraFlags = ( finished => 0 );
        }

        # Add the build to the database.
        $build = $job->builds->create(
            { timestamp => $time
            , description => $buildInfo->{description}
            , longdescription => $buildInfo->{longDescription}
            , license => $buildInfo->{license}
            , homepage => $buildInfo->{homepage}
            , maintainers => $buildInfo->{maintainers}
            , maxsilent => $buildInfo->{maxSilent}
            , timeout => $buildInfo->{timeout}
            , nixname => $buildInfo->{nixName}
            , drvpath => $drvPath
            , system => $buildInfo->{system}
            , nixexprinput => $jobset->nixexprinput
            , nixexprpath => $jobset->nixexprpath
            , priority => $priority
            , busy => 0
            , locker => ""
            , %extraFlags
            });

        $build->buildoutputs->create({ name => $_, path => $buildInfo->{output}->{$_}->{path} })
            foreach @outputNames;

        $buildIds->{$build->id} = 1;
        $$jobOutPathMap{$job->name . "\t" . $firstOutputPath} = $build->id;

        if ($build->iscachedbuild) {
            print STDERR "    marked as cached build ", $build->id, "\n";
            addBuildProducts($db, $build);
        } else {
            print STDERR "    added to queue as build ", $build->id, "\n";
        }

        # Record which inputs where used.
        my %inputs;
        $inputs{$jobset->nixexprinput} = $nixExprInput;
        foreach my $name (keys %{$inputInfo}) {
            # Unconditionally include all inputs that were included in
            # the Nix search path (through the -I flag).  We currently
            # have no way to see which ones were actually used.
            $inputs{$name} = $inputInfo->{$name}->[0]
                if scalar @{$inputInfo->{$name}} == 1
                   && defined $inputInfo->{$name}->[0]->{storePath};
        }
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

    return $build;
};


sub restartBuild {
    my ($db, $build) = @_;

    txn_do($db, sub {
        my @paths;
        push @paths, $build->drvpath;
        push @paths, $_->drvpath foreach $build->buildsteps;

        my $r = `nix-store --clear-failed-paths @paths`;

        $build->update(
            { finished => 0
            , busy => 0
            , locker => ""
            , iscachedbuild => 0
            });

        $build->buildproducts->delete_all;

        # Reset the stats for the evals to which this build belongs.
        # !!! Should do this in a trigger.
        foreach my $m ($build->jobsetevalmembers->all) {
            $m->eval->update({nrsucceeded => undef});
        }
    });
}
