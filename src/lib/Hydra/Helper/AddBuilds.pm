package Hydra::Helper::AddBuilds;

use strict;
use feature 'switch';
use XML::Simple;
use POSIX qw(strftime);
use IPC::Run;
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(fetchInput evalJobs checkBuild inputsToArgs);


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

sub fetchInputPath {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

        my $uri = $value;

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

            print STDERR "copying input ", $name, " from $uri\n";
            $storePath = `nix-store --add "$uri"`
                or die "Cannot copy path $uri to the Nix store.\n";
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

sub fetchInputSVN {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

        my $uri = $value;

        my $sha256;
        my $storePath;

        # First figure out the last-modified revision of the URI.
        my @cmd = (["svn", "ls", "-v", "--depth", "empty", $uri],
                   "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);
        my $stdout; my $stderr;
        die "Cannot get head revision of Subversion repository at `$uri':\n$stderr"
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
            print STDERR "checking out Subversion input ", $name, " from $uri revision $revision\n";
            $ENV{"NIX_HASH_ALGO"} = "sha256";
            $ENV{"PRINT_PATH"} = "1";
            (my $res, $stdout, $stderr) = captureStdoutStderr(
                "nix-prefetch-svn", $uri, $revision);
            die "Cannot check out Subversion repository `$uri':\n$stderr" unless $res;

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

sub fetchInputBuild {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

        my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
        $projectName ||= $project->name;
        $jobsetName ||= $jobset->name;

        # Pick the most recent successful build of the specified job.
        (my $prevBuild) = $db->resultset('Builds')->search(
            { finished => 1, project => $projectName, jobset => $jobsetName
            , job => $jobName, buildStatus => 0 },
            { join => 'resultInfo', order_by => "me.id DESC", rows => 1
            , where => \ attrsToSQL($attrs, "me.id") });

        if (!defined $prevBuild || !isValidPath($prevBuild->outpath)) {
            print STDERR "input `", $name, "': no previous build available\n";
            return undef;
        }

        #print STDERR "input `", $name, "': using build ", $prevBuild->id, "\n";

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

sub fetchInputSystemBuild {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

        my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
        $projectName ||= $project->name;
        $jobsetName ||= $jobset->name;

        my @latestBuilds = $db->resultset('LatestSucceededForJob')
          ->search({}, {bind => [$projectName, $jobsetName, $jobName]});

        my @validBuilds = ();
        foreach my $build (@latestBuilds) {
        	if(isValidPath($build->outpath)) {
        		push(@validBuilds,$build);
        	}
        }
        
        if (scalar(@validBuilds) == 0) {
            print STDERR "input `", $name, "': no previous build available\n";
            return undef;
        }

		my @inputs = ();
        foreach my $prevBuild (@validBuilds) {
	        my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
	        my $versionRE = "(?:[A-Za-z0-9\.\-]+)";
	
	        my $relName = ($prevBuild->resultInfo->releasename or $prevBuild->nixname);
	        my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;
	        
	        my $input =
	            { type => "sysbuild"
	            , storePath => $prevBuild->outpath
	            , id => $prevBuild->id
	            , version => $version
	            , system => $prevBuild->system
	            };
	        push(@inputs, $input);
		}
		return @inputs;		        
}

sub fetchInputGit {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

    (my $uri, my $branch) = split ' ', $value;
    $branch = defined $branch ? $branch : "master"; 

    my $timestamp = time;
    my $sha256;
    my $storePath;

    # First figure out the last-modified revision of the URI.
    my $stdout; my $stderr;
    (my $res, $stdout, $stderr) = captureStdoutStderr(
	    "git", "ls-remote", $uri, $branch);
    die "Cannot get head revision of Git branch '$branch' at `$uri':\n$stderr" unless $res;

    (my $revision, my $ref) = split ' ', $stdout;
    die unless $revision =~ /^[0-9a-fA-F]+$/;

    # Some simple caching: don't check a uri/branch more than once every hour, but prefer exact match on uri/branch/revision.
    my $cachedInput ;
    ($cachedInput) = $db->resultset('CachedGitInputs')->search(
	{uri => $uri, branch => $branch, revision => $revision},
	{rows => 1});
    if (! defined $cachedInput ) {
	($cachedInput) = $db->resultset('CachedGitInputs')->search(
	    {uri => $uri, branch => $branch, lastseen => {">", $timestamp - 3600}},
	    {rows => 1, order_by => "lastseen DESC"});
    }

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
	$storePath = $cachedInput->storepath;
	$sha256 = $cachedInput->sha256hash;
	$timestamp = $cachedInput->timestamp;
	$revision = $cachedInput->revision;
    } else {

	# Then download this revision into the store.
	print STDERR "checking out Git input from $uri";
	$ENV{"NIX_HASH_ALGO"} = "sha256";
	$ENV{"PRINT_PATH"} = "1";

	# Checked out code often wants to be able to run `git
	# describe', e.g., code that uses Gnulib's `git-version-gen'
	# script.  Thus, we leave `.git' in there.  Same for
	# Subversion (e.g., libgcrypt's build system uses that.)
	$ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "1";
	$ENV{"NIX_PREFETCH_SVN_LEAVE_DOT_SVN"} = "1";

	# Ask for a "deep clone" to allow "git describe" and similar
	# tools to work.  See
	# http://thread.gmane.org/gmane.linux.distributions.nixos/3569
	# for a discussion.
	$ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "1";

	(my $res, $stdout, $stderr) = captureStdoutStderr(
	    "nix-prefetch-git", $uri, $revision);
	die "Cannot check out Git repository branch '$branch' at `$uri':\n$stderr" unless $res;

	($sha256, $storePath) = split ' ', $stdout;
	($cachedInput) = $db->resultset('CachedGitInputs')->search(
	    {uri => $uri, branch => $branch, sha256hash => $sha256});

	if (!defined $cachedInput) {
	    txn_do($db, sub {
		$db->resultset('CachedGitInputs')->create(
		    { uri => $uri
                    , branch => $branch
                    , revision => $revision
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
       , revision => $revision
       };

}

sub fetchInputCVS {
    my ($db, $project, $jobset, $name, $type, $value) = @_;
}

sub fetchInput {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

    if ($type eq "path") {
	return fetchInputPath($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "svn") {
	return fetchInputSVN($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "build") {
	return fetchInputBuild($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "sysbuild") {
	return fetchInputSystemBuild($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "git") {
	return fetchInputGit($db, $project, $jobset, $name, $type, $value);
    }
    
    elsif ($type eq "string") {
        die unless defined $value;
        return {type => $type, value => $value};
    }
    
    elsif ($type eq "boolean") {
        die unless defined $value && ($value eq "true" || $value eq "false");
        return {type => $type, value => $value};
    }
    
    else {
        die "Input `" . $name . "' has unknown type `$type'.";
    }
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
                when (["svn", "path", "build", "git", "cvs", "sysbuild"]) {
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


sub captureStdoutStderr {
    my $stdin = ""; my $stdout; my $stderr;
    my $res = IPC::Run::run(\@_, \$stdin, \$stdout, \$stderr);
    return ($res, $stdout, $stderr);
}

    
sub evalJobs {
    my ($inputInfo, $nixExprInputName, $nixExprPath) = @_;

    my $nixExprInput = $inputInfo->{$nixExprInputName}->[0]
        or die "Cannot find the input containing the job expression.\n";
    die "Multiple alternatives for the input containing the Nix expression are not supported.\n"
        if scalar @{$inputInfo->{$nixExprInputName}} != 1;
    my $nixExprFullPath = $nixExprInput->{storePath} . "/" . $nixExprPath;
    
    (my $res, my $jobsXml, my $stderr) = captureStdoutStderr(
        "hydra_eval_jobs", $nixExprFullPath, "--gc-roots-dir", getGCRootsDir,
        inputsToArgs($inputInfo));
    die "Cannot evaluate the Nix expression containing the jobs:\n$stderr" unless $res;

    print STDERR "$stderr";

    my $jobs = XMLin(
        $jobsXml,
        ForceArray => ['error', 'job', 'arg'],
        KeyAttr => [],
        SuppressEmpty => '')
        or die "cannot parse XML output";

    my @filteredJobs = ();
    foreach my $job (@{$jobs->{job}}) {
    	my $validJob = 1;
  		foreach my $arg (@{$job->{arg}}) {
  			my $input = $inputInfo->{$arg->{name}}->[$arg->{altnr}] ;
  			if($input->{type} eq "sysbuild" && ! ($input->{system} eq $job->{system}) ) {
  				$validJob = 0 ;
  			}
    	}
    	if($validJob) {
    	  push(@filteredJobs, $job);
    	}    	
    }
    $jobs->{job} = \@filteredJobs;
    
    return ($jobs, $nixExprInput);
}


# Check whether to add the build described by $buildInfo.
sub checkBuild {
    my ($db, $project, $jobset, $inputInfo, $nixExprInput, $buildInfo, $currentBuilds) = @_;

    my $jobName = $buildInfo->{jobName};
    my $drvPath = $buildInfo->{drvPath};
    my $outPath = $buildInfo->{outPath};

    my $priority = 100;
    $priority = int($buildInfo->{schedulingPriority})
        if $buildInfo->{schedulingPriority} =~ /^\d+$/;

    my $build;

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
            print STDERR "already scheduled/built\n";
            $currentBuilds->{$_->id} = 1 foreach @previousBuilds;
            return;
        }
        
        # Nope, so add it.
        $build = $job->builds->create(
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

        print STDERR "added to queue as build ", $build->id, "\n";
        
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

    return $build;
};
