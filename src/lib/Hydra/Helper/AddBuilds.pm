package Hydra::Helper::AddBuilds;

use strict;
use utf8;
use Encode;
use JSON;
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
use Hydra::Helper::PluginHooks;
use Hydra::Helper::CatalystUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    fetchInput evalJobs checkBuild inputsToArgs
    restartBuild getPrevJobsetEval updateDeclarativeJobset
    handleDeclarativeJobsetBuild
);


sub parseJobName {
    # Parse a job specification of the form `<project>:<jobset>:<job>
    # [attrs]'.  The project, jobset and attrs may be omitted.  The
    # attrs have the form `name = "value"'.
    my ($s) = @_;
    our $key;
    our %attrs = ();
    # hm, maybe I should stop programming Perl before it's too late...
    $s =~ / ^ (?: (?: ($projectNameRE) : )? ($jobsetNameRE) : )? ($jobNameRE) \s*
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

    my $prevBuild;

    if ($value =~ /^\d+$/) {
        $prevBuild = $db->resultset('Builds')->find({ id => int($value) });
    } else {
        my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
        $projectName ||= $project->name;
        $jobsetName ||= $jobset->name;

        # Pick the most recent successful build of the specified job.
        $prevBuild = $db->resultset('Builds')->search(
            { finished => 1, project => $projectName, jobset => $jobsetName
            , job => $jobName, buildStatus => 0 },
            { order_by => "me.id DESC", rows => 1
            , where => \ attrsToSQL($attrs, "me.id") })->single;
    }

    return () if !defined $prevBuild || !isValidPath(getMainOutput($prevBuild)->path);

    #print STDERR "input `", $name, "': using build ", $prevBuild->id, "\n";

    my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
    my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

    my $relName = ($prevBuild->releasename or $prevBuild->nixname);
    my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;

    my $mainOutput = getMainOutput($prevBuild);

    my $result =
        { storePath => $mainOutput->path
        , id => $prevBuild->id
        , version => $version
        , outputName => $mainOutput->name
        };
    if (isValidPath($prevBuild->drvpath)) {
        $result->{drvPath} = $prevBuild->drvpath;
    }

    return $result;
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


sub fetchInputEval {
    my ($db, $project, $jobset, $name, $value) = @_;

    my $eval;

    if ($value =~ /^\d+$/) {
        $eval = $db->resultset('JobsetEvals')->find({ id => int($value) });
        die "evaluation $eval->{id} does not exist\n" unless defined $eval;
    } elsif ($value =~ /^($projectNameRE):($jobsetNameRE)$/) {
        my $jobset = $db->resultset('Jobsets')->find({ project => $1, name => $2 });
        die "jobset ‘$value’ does not exist\n" unless defined $jobset;
        $eval = getLatestFinishedEval($jobset);
        die "jobset ‘$value’ does not have a finished evaluation\n" unless defined $eval;
    } elsif ($value =~ /^($projectNameRE):($jobsetNameRE):($jobNameRE)$/) {
        $eval = $db->resultset('JobsetEvals')->find(
            { project => $1, jobset => $2, hasnewbuilds => 1 },
            { order_by => "id DESC", rows => 1
            , where =>
                \ [ # All builds in this jobset should be finished...
                    "not exists (select 1 from JobsetEvalMembers m join Builds b on m.build = b.id where m.eval = me.id and b.finished = 0) "
                    # ...and the specified build must have succeeded.
                    . "and exists (select 1 from JobsetEvalMembers m join Builds b on m.build = b.id where m.eval = me.id and b.job = ? and b.buildstatus = 0)"
                  , [ 'name', $3 ] ]
            });
        die "there is no successful build of ‘$value’ in a finished evaluation\n" unless defined $eval;
    } else {
        die;
    }

    my $jobs = {};
    foreach my $build ($eval->builds) {
        next unless $build->finished == 1 && $build->buildstatus == 0;
        # FIXME: Handle multiple outputs.
        my $out = $build->buildoutputs->find({ name => "out" });
        next unless defined $out;
        # FIXME: Should we fail if the path is not valid?
        next unless isValidPath($out->path);
        $jobs->{$build->get_column('job')} = $out->path;
    }

    return { jobs => $jobs };
}


sub fetchInput {
    my ($plugins, $db, $project, $jobset, $name, $type, $value, $emailresponsible) = @_;
    my @inputs;

    if ($type eq "build") {
        @inputs = fetchInputBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "sysbuild") {
        @inputs = fetchInputSystemBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "eval") {
        @inputs = fetchInputEval($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "string" || $type eq "nix") {
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
            @inputs = $plugin->fetchInput($type, $name, $value, $project, $jobset);
            if (defined $inputs[0]) {
                $found = 1;
                last;
            }
        }
        die "input `$name' has unknown type `$type'." unless $found;
    }

    foreach my $input (@inputs) {
        $input->{type} = $type;
        $input->{emailresponsible} = $emailresponsible;
    }

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
            "; inputType = \"" . $input->{type} . "\"" .
            (defined $input->{uri} ? "; uri = \"" . $input->{uri} . "\"" : "") .
            (defined $input->{revNumber} ? "; rev = " . $input->{revNumber} . "" : "") .
            (defined $input->{revision} ? "; rev = \"" . $input->{revision} . "\"" : "") .
            (defined $input->{revCount} ? "; revCount = " . $input->{revCount} . "" : "") .
            (defined $input->{gitTag} ? "; gitTag = \"" . $input->{gitTag} . "\"" : "") .
            (defined $input->{shortRev} ? "; shortRev = \"" . $input->{shortRev} . "\"" : "") .
            (defined $input->{version} ? "; version = \"" . $input->{version} . "\"" : "") .
            (defined $input->{outputName} ? "; outputName = \"" . $input->{outputName} . "\"" : "") .
            (defined $input->{drvPath} ? "; drvPath = builtins.storePath " . $input->{drvPath} . "" : "") .
            ";}";
    }
    return $result;
}


sub inputsToArgs {
    my ($inputInfo, $exprType) = @_;
    my @res = ();

    foreach my $input (sort keys %{$inputInfo}) {
        push @res, "-I", "$input=$inputInfo->{$input}->[0]->{storePath}"
            if scalar @{$inputInfo->{$input}} == 1
               && defined $inputInfo->{$input}->[0]->{storePath};
        foreach my $alt (@{$inputInfo->{$input}}) {
            if ($alt->{type} eq "string") {
                push @res, "--argstr", $input, $alt->{value};
            }
            elsif ($alt->{type} eq "boolean") {
                push @res, "--arg", $input, booleanToString($exprType, $alt->{value});
            }
            elsif ($alt->{type} eq "nix") {
                die "input type ‘nix’ only supported for Nix-based jobsets\n" unless $exprType eq "nix";
                push @res, "--arg", $input, $alt->{value};
            }
            elsif ($alt->{type} eq "eval") {
                die "input type ‘eval’ only supported for Nix-based jobsets\n" unless $exprType eq "nix";
                my $s = "{ ";
                # FIXME: escape $_.  But dots should not be escaped.
                $s .= "$_ = builtins.storePath ${\$alt->{jobs}->{$_}}; "
                    foreach keys %{$alt->{jobs}};
                $s .= "}";
                push @res, "--arg", $input, $s;
            }
            else {
                push @res, "--arg", $input, buildInputToString($exprType, $alt);
            }
        }
    }

    return @res;
}


sub evalJobs {
    my ($inputInfo, $exprType, $nixExprInputName, $nixExprPath) = @_;

    my $nixExprInput = $inputInfo->{$nixExprInputName}->[0]
        or die "cannot find the input containing the job expression\n";
    die "multiple alternatives for the input containing the Nix expression are not supported.\n"
        if scalar @{$inputInfo->{$nixExprInputName}} != 1;
    my $nixExprFullPath = $nixExprInput->{storePath} . "/" . $nixExprPath;

    my $evaluator = ($exprType eq "guile") ? "hydra-eval-guile-jobs" : "hydra-eval-jobs";

    my @cmd = ($evaluator, $nixExprFullPath, "--gc-roots-dir", getGCRootsDir, "-j", 1, inputsToArgs($inputInfo, $exprType));

    if (defined $ENV{'HYDRA_DEBUG'}) {
        sub escape {
            my $s = $_;
            $s =~ s/'/'\\''/g;
            return "'" . $s . "'";
        }
        my @escaped = map escape, @cmd;
        print STDERR "evaluator: @escaped\n";
    }

    (my $res, my $jobsJSON, my $stderr) = captureStdoutStderr(21600, @cmd);
    die "$evaluator returned " . ($res & 127 ? "signal $res" : "exit code " . ($res >> 8))
        . ":\n" . ($stderr ? decode("utf-8", $stderr) : "(no output)\n")
        if $res;

    print STDERR "$stderr";

    return (decode_json($jobsJSON), $nixExprInput);
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
    my ($db, $jobset, $inputInfo, $nixExprInput, $buildInfo, $buildMap, $prevEval, $jobOutPathMap, $plugins) = @_;

    my @outputNames = sort keys %{$buildInfo->{outputs}};
    die unless scalar @outputNames;

    # In various checks we can use an arbitrary output (the first)
    # rather than all outputs, since if one output is the same, the
    # others will be as well.
    my $firstOutputName = $outputNames[0];
    my $firstOutputPath = $buildInfo->{outputs}->{$firstOutputName};

    my $jobName = $buildInfo->{jobName} or die;
    my $drvPath = $buildInfo->{drvPath} or die;

    my $build;

    txn_do($db, sub {
        my $job = $jobset->jobs->update_or_create({ name => $jobName });

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
                { project => $jobset->project->name, jobset => $jobset->name, job => $jobName,
                  name => $firstOutputName, path => $firstOutputPath },
                { rows => 1, columns => ['id'], join => ['buildoutputs'] });
            if (defined $prevBuild) {
                #print STDERR "    already scheduled/built as build ", $prevBuild->id, "\n";
                $buildMap->{$prevBuild->id} = { id => $prevBuild->id, jobName => $jobName, new => 0, drvPath => $drvPath };
                return;
            }
        }

        # Prevent multiple builds with the same (job, outPath) from
        # being added.
        my $prev = $$jobOutPathMap{$jobName . "\t" . $firstOutputPath};
        if (defined $prev) {
            #print STDERR "    already scheduled as build ", $prev, "\n";
            return;
        }

        my $time = time();

        sub null {
            my ($s) = @_;
            return $s eq "" ? undef : $s;
        }

        # Add the build to the database.
        $build = $job->builds->create(
            { timestamp => $time
            , description => null($buildInfo->{description})
            , license => null($buildInfo->{license})
            , homepage => null($buildInfo->{homepage})
            , maintainers => null($buildInfo->{maintainers})
            , maxsilent => $buildInfo->{maxSilent}
            , timeout => $buildInfo->{timeout}
            , nixname => $buildInfo->{nixName}
            , drvpath => $drvPath
            , system => $buildInfo->{system}
            , nixexprinput => $jobset->nixexprinput
            , nixexprpath => $jobset->nixexprpath
            , priority => $buildInfo->{schedulingPriority}
            , finished => 0
            , iscurrent => 1
            , ischannel => $buildInfo->{isChannel}
            });

        $build->buildoutputs->create({ name => $_, path => $buildInfo->{outputs}->{$_} })
            foreach @outputNames;

        $buildMap->{$build->id} = { id => $build->id, jobName => $jobName, new => 1, drvPath => $drvPath };
        $$jobOutPathMap{$jobName . "\t" . $firstOutputPath} = $build->id;

        print STDERR "added build ${\$build->id} (${\$jobset->project->name}:${\$jobset->name}:$jobName)\n";
    });

    return $build;
};


sub updateDeclarativeJobset {
    my ($db, $project, $jobsetName, $declSpec) = @_;

    my @allowed_keys = qw(
        enabled
        hidden
        description
        nixexprinput
        nixexprpath
        checkinterval
        schedulingshares
        enableemail
        emailoverride
        keepnr
    );
    my %update = ( name => $jobsetName );
    foreach my $key (@allowed_keys) {
        $update{$key} = $declSpec->{$key};
        delete $declSpec->{$key};
    }
    txn_do($db, sub {
        my $jobset = $project->jobsets->update_or_create(\%update);
        $jobset->jobsetinputs->delete;
        while ((my $name, my $data) = each %{$declSpec->{"inputs"}}) {
            my $input = $jobset->jobsetinputs->create(
                { name => $name,
                  type => $data->{type},
                  emailresponsible => $data->{emailresponsible}
                });
            $input->jobsetinputalts->create({altnr => 0, value => $data->{value}});
        }
        delete $declSpec->{"inputs"};
        die "invalid keys in declarative specification file\n" if (%{$declSpec});
    });
};


sub handleDeclarativeJobsetBuild {
    my ($db, $project, $build) = @_;

    eval {
        my $id = $build->id;
        die "Declarative jobset build $id failed" unless $build->buildstatus == 0;
        my $declPath = ($build->buildoutputs)[0]->path;
        my $declText = read_file($declPath)
            or die "Couldn't read declarative specification file $declPath: $!";
        my $declSpec = decode_json($declText);
        txn_do($db, sub {
            my @kept = keys %$declSpec;
            push @kept, ".jobsets";
            $project->jobsets->search({ name => { "not in" => \@kept } })->update({ enabled => 0, hidden => 1 });
            while ((my $jobsetName, my $spec) = each %$declSpec) {
                updateDeclarativeJobset($db, $project, $jobsetName, $spec);
            }
        });
    };
    $project->jobsets->find({ name => ".jobsets" })->update({ errormsg => $@, errortime => time, fetcherrormsg => undef })
        if defined $@;

};


1;
