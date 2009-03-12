#! /var/run/current-system/sw/bin/perl -w

use strict;
use feature 'switch';
use XML::Simple;
use Hydra::Schema;
use Hydra::Helper::Nix;
use IPC::Run;
use POSIX qw(strftime);


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
                $db->txn_do(sub {
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
                $db->txn_do(sub {
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

            $db->txn_do(sub {
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
        my $jobName = $alt->value or die;

        # Pick the most recent successful build of the specified job.
        (my $prevBuild) = $db->resultset('Builds')->search(
            {finished => 1, project => $project->name, jobset => $jobset->name, job => $jobName, buildStatus => 0},
            {join => 'resultInfo', order_by => "timestamp DESC", rows => 1});

        if (!defined $prevBuild || !isValidPath($prevBuild->outpath)) {
            print STDERR "no previous build available for `$jobName'";
            return undef;
        }

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
    my ($project, $jobset, $inputInfo, $job) = @_;

    my $jobName = $job->{jobName};
    my $drvPath = $job->{drvPath};
    my $outPath = $job->{outPath};

    my $priority = 100;
    $priority = int($job->{schedulingPriority})
        if $job->{schedulingPriority} =~ /^\d+$/;

    $db->txn_do(sub {
        if (scalar($db->resultset('Builds')->search(
                { project => $project->name, jobset => $jobset->name
                , job => $jobName, outPath => $outPath })) > 0)
        {
            print "already scheduled/done\n";
            return;
        }

        print "adding to queue\n";
        
        my $build = $db->resultset('Builds')->create(
            { finished => 0
            , timestamp => time()
            , project => $project->name
            , jobset => $jobset->name
            , job => $jobName
            , description => $job->{description}
            , longdescription => $job->{longDescription}
            , license => $job->{license}
            , homepage => $job->{homepage}
            , nixname => $job->{nixName}
            , drvpath => $drvPath
            , outpath => $outPath
            , system => $job->{system}
            });

        $db->resultset('BuildSchedulingInfo')->create(
            { id => $build->id
            , priority => $priority
            , busy => 0
            , locker => ""
            });

        foreach my $arg (@{$job->{arg}}) {
            my $input = $inputInfo->{$arg->{name}}->[$arg->{altnr}] or die "invalid input";
            $db->resultset('BuildInputs')->create(
                { build => $build->id
                , name => $arg->{name}
                , type => $input->{type}
                , uri => $input->{uri}
                , revision => $input->{revision}
                , value => $input->{value}
                , dependency => $input->{id}
                , path => ($input->{storePath} or "") # !!! temporary hack
                , sha256hash => $input->{sha256hash}
                });
        }
        
        # !!! this should really by done by nix-instantiate to prevent a GC race.
        registerRoot $drvPath;
    });
};


sub setJobsetError {
    my ($jobset, $errorMsg) = @_;
    eval {
        $db->txn_do(sub {
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


sub checkJobSet {
    my ($project, $jobset) = @_;
    my $inputInfo = {};
    
    $db->txn_do(sub {
        $jobset->update({lastcheckedtime => time});
    });

    # Fetch all values for all inputs.
    fetchInputs($project, $jobset, $inputInfo);

    # Evaluate the job expression.
    my $nixExprPath = $inputInfo->{$jobset->nixexprinput}->[0]->{storePath}
        or die "cannot find the input containing the job expression";
    $nixExprPath .= "/" . $jobset->nixexprpath;

    (my $res, my $jobsXml, my $stderr) = captureStdoutStderr(
        "hydra_eval_jobs", $nixExprPath, inputsToArgs($inputInfo));
    die "cannot evaluate the Nix expression containing the jobs:\n$stderr" unless $res;

    my $jobs = XMLin($jobsXml,
                     ForceArray => ['error', 'job', 'arg'],
                     KeyAttr => [],
                     SuppressEmpty => '')
        or die "cannot parse XML output";

    # Schedule each successfully evaluated job.
    foreach my $job (@{$jobs->{job}}) {
        print "considering job " . $job->{jobName} . "\n";
        checkJob($project, $jobset, $inputInfo, $job);
    }

    # Store the errors messages for jobs that failed to evaluate.
    my $msg = "";
    foreach my $error (@{$jobs->{error}}) {
        $msg .= "at `" . $error->{location} . "': " . $error->{msg} . "\n";
    }
    setJobsetError($jobset, $msg);
}


sub checkJobs {

    foreach my $project ($db->resultset('Projects')->search({enabled => 1})) {
        print "considering project ", $project->name, "\n";
        foreach my $jobset ($project->jobsets->all) {
            print "considering jobset ", $jobset->name, " in ", $project->name, "\n";
            eval {
                checkJobSet($project, $jobset);
            };
            if ($@) {
                print "error evaluating jobset ", $jobset->name, ": $@";
                setJobsetError($jobset, $@);
            }
        }
    }
    
}


# For testing: evaluate a single jobset, then exit.
if (scalar @ARGV == 2) {
    my $projectName = $ARGV[0];
    my $jobsetName = $ARGV[1];
    my $jobset = $db->resultset('Jobsets')->find($projectName, $jobsetName) or die;
    checkJobSet($jobset->project, $jobset);
    exit 0;
}


while (1) {
    checkJobs;
    print "sleeping...\n";
    sleep 30;
}
