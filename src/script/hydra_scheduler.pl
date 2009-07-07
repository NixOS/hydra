#! /var/run/current-system/sw/bin/perl -w

use strict;
use feature 'switch';
use XML::Simple;
use Hydra::Schema;
use Hydra::Helper::Nix;
use IPC::Run;
use POSIX qw(strftime);


STDOUT->autoflush();

my $db = openHydraDB;


sub captureStdoutStderr {
    my $stdin = ""; my $stdout; my $stderr;
    my $res = IPC::Run::run(\@_, \$stdin, \$stdout, \$stderr);
    return ($res, $stdout, $stderr);
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


sub parseJobName {
    # Parse a job specification of the form `<project>:<jobset>:<job>
    # [attrs]'.  The project, jobset and attrs may be omitted.  The
    # attrs have the form `name = "value"'.
    my ($s) = @_;
    our $key;
    our %attrs = ();
    # hm, maybe I should stop programming Perl before it's too late...
    $s =~ / ^ (?: (?: ([\w\-]+) : )? ([\w\-]+) : )? ([\w\-]+) \s*
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


sub fetchInputAlt {
    my ($project, $jobset, $input, $alt) = @_;
    my $type = $input->type;

    if ($type eq "path") {
        my $uri = $alt->value;

        my $timestamp = time;
        my $sha256;
        my $storePath;

        # Some simple caching: don't check a path more than once every N seconds.
        (my $cachedInput) = $db->resultset('CachedPathInputs')->search(
            {srcpath => $uri, lastseen => {">", $timestamp - 60}},
            {rows => 1, order_by => "lastseen DESC"});

        if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
            $storePath = $cachedInput->storepath;
            $sha256 = $cachedInput->sha256hash;
            $timestamp = $cachedInput->timestamp;
        } else {

            print "copying input ", $input->name, " from $uri\n";
            $storePath = `nix-store --add "$uri"`
                or die "cannot copy path $uri to the Nix store";
            chomp $storePath;

            $sha256 = getStorePathHash $storePath;

            ($cachedInput) = $db->resultset('CachedPathInputs')->search(
                {srcpath => $uri, sha256hash => $sha256});

            # Path inputs don't have a natural notion of a "revision",
            # so we simulate it by using the timestamp that we first
            # saw this path have this SHA-256 hash.  So if the
            # contents of the path changes, we get a new "revision",
            # but if it doesn't change (or changes back), we don't get
            # a new "revision".
            if (!defined $cachedInput) {
                txn_do($db, sub {
                    $db->resultset('CachedPathInputs')->create(
                        { srcpath => $uri
                        , timestamp => $timestamp
                        , lastseen => $timestamp
                        , sha256hash => $sha256
                        , storepath => $storePath
                        });
                });
            } else {
                $timestamp = $cachedInput->timestamp;
                txn_do($db, sub {
                    $cachedInput->update({lastseen => time});
                });
            }
        }

        return
            { type => $type
            , uri => $uri
            , storePath => $storePath
            , sha256hash => $sha256
            , revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp)
            };
    }

    elsif ($type eq "svn") {
        my $uri = $alt->value;

        my $sha256;
        my $storePath;

        # First figure out the last-modified revision of the URI.
        my @cmd = (["svn", "ls", "-v", "--depth", "empty", $uri],
                   "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);
        my $stdout; my $stderr;
        die "cannot get head revision of Subversion repository at `$uri':\n$stderr"
            unless IPC::Run::run(@cmd, \$stdout, \$stderr);
        my $revision = $stdout; chomp $revision;
        die unless $revision =~ /^\d+$/;

        (my $cachedInput) = $db->resultset('CachedSubversionInputs')->search(
            {uri => $uri, revision => $revision});

        if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
            $storePath = $cachedInput->storepath;
            $sha256 = $cachedInput->sha256hash;
        } else {
            
            # Then download this revision into the store.
            print "checking out Subversion input ", $input->name, " from $uri revision $revision\n";
            $ENV{"NIX_HASH_ALGO"} = "sha256";
            $ENV{"PRINT_PATH"} = "1";
            (my $res, $stdout, $stderr) = captureStdoutStderr(
                "nix-prefetch-svn", $uri, $revision);
            die "cannot check out Subversion repository `$uri':\n$stderr" unless $res;

            ($sha256, $storePath) = split ' ', $stdout;

            txn_do($db, sub {
                $db->resultset('CachedSubversionInputs')->create(
                    { uri => $uri
                    , revision => $revision
                    , sha256hash => $sha256
                    , storepath => $storePath
                    });
            });
        }

        return 
            { type => $type
            , uri => $uri
            , storePath => $storePath
            , sha256hash => $sha256
            , revision => $revision
            };
    }

    elsif ($type eq "build") {
        my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($alt->value);
        $projectName ||= $project->name;
        $jobsetName ||= $jobset->name;

        # Pick the most recent successful build of the specified job.
        (my $prevBuild) = $db->resultset('Builds')->search(
            { finished => 1, project => $projectName, jobset => $jobsetName
            , job => $jobName, buildStatus => 0 },
            { join => 'resultInfo', order_by => "me.id DESC", rows => 1
            , where => \ attrsToSQL($attrs, "me.id") });

        if (!defined $prevBuild || !isValidPath($prevBuild->outpath)) {
            print STDERR "input `", $input->name, "': no previous build available\n";
            return undef;
        }

        #print STDERR "input `", $input->name, "': using build ", $prevBuild->id, "\n";

        my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
        my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

        my $relName = ($prevBuild->resultInfo->releasename or $prevBuild->nixname);
        my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;
        
        return 
            { type => "build"
            , storePath => $prevBuild->outpath
            , id => $prevBuild->id
            , version => $version
            };
    }
    
    elsif ($type eq "string") {
        die unless defined $alt->value;
        return {type => $type, value => $alt->value};
    }
    
    elsif ($type eq "boolean") {
        die unless defined $alt->value && ($alt->value eq "true" || $alt->value eq "false");
        return {type => $type, value => $alt->value};
    }
    
    else {
        die "input `" . $input->name . "' has unknown type `$type'";
    }
}


sub fetchInputs {
    my ($project, $jobset, $inputInfo) = @_;
    foreach my $input ($jobset->jobsetinputs->all) {
        foreach my $alt ($input->jobsetinputalts->all) {
            my $info = fetchInputAlt($project, $jobset, $input, $alt);
            push @{$$inputInfo{$input->name}}, $info if defined $info;
        }
    }
}


sub checkJob {
    my ($project, $jobset, $inputInfo, $nixExprInput, $job) = @_;

    my $jobName = $job->{jobName};
    my $drvPath = $job->{drvPath};
    my $outPath = $job->{outPath};

    my $priority = 100;
    $priority = int($job->{schedulingPriority})
        if $job->{schedulingPriority} =~ /^\d+$/;

    txn_do($db, sub {
        # Mark this job as active in the database.
        my $jobInDB = $jobset->jobs->update_or_create(
            { name => $jobName
            , active => 1
            , lastevaltime => time
            });

        $jobInDB->update({firstevaltime => time})
            unless defined $jobInDB->firstevaltime;

        # Have we already done this build (in this job)?
        if (scalar($jobInDB->builds->search({outPath => $outPath})) > 0) {
            print "already scheduled/done\n";
            return;
        }

        # Nope, so add it.
        print "adding to queue\n";
        
        my $build = $jobInDB->builds->create(
            { finished => 0
            , timestamp => time()
            , description => $job->{description}
            , longdescription => $job->{longDescription}
            , license => $job->{license}
            , homepage => $job->{homepage}
            , nixname => $job->{nixName}
            , drvpath => $drvPath
            , outpath => $outPath
            , system => $job->{system}
            });

        $build->create_related('buildschedulinginfo',
            { priority => $priority
            , busy => 0
            , locker => ""
            });

        my %inputs;
        $inputs{$jobset->nixexprinput} = $nixExprInput;
        foreach my $arg (@{$job->{arg}}) {
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
    foreach my $job (permute @{$jobs->{job}}) {
        next if $job->{jobName} eq "";
        print "considering job " . $job->{jobName} . "\n";
        checkJob($project, $jobset, $inputInfo, $nixExprInput, $job);
    }

    # Mark all existing jobs that we haven't seen as inactive.
    my %jobNames;
    $jobNames{$_->{jobName}}++ foreach @{$jobs->{job}};
    
    my %failedJobNames;
    push @{$failedJobNames{$_->{location}}}, $_->{msg} foreach @{$jobs->{error}};
    
    txn_do($db, sub {
        $jobset->update({lastcheckedtime => time});
        
        foreach my $jobInDB ($jobset->jobs->all) {
            $jobInDB->update({active => $jobNames{$jobInDB->name} || $failedJobNames{$jobInDB->name} ? 1 : 0});

            if ($failedJobNames{$jobInDB->name}) {
                $jobInDB->update({errormsg => join '\n', @{$failedJobNames{$jobInDB->name}}});
            } else {
                $jobInDB->update({errormsg => undef});
            }
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


sub checkJobs {
    foreach my $project ($db->resultset('Projects')->search({enabled => 1})) {
        print "considering project ", $project->name, "\n";
        checkJobsetWrapped($project, $_) foreach $project->jobsets->all;
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
        checkJobs;
    };
    if ($@) { print "$@"; }
    print "sleeping...\n";
    sleep 30;
}
