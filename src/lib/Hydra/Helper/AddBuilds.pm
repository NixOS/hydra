package Hydra::Helper::AddBuilds;

use strict;
use feature 'switch';
use XML::Simple;
use POSIX qw(strftime);
use IPC::Run;
use Hydra::Helper::Nix;
use Digest::SHA qw(sha256_hex);
use File::Basename;
use File::stat;
use File::Path;

our @ISA = qw(Exporter);
our @EXPORT = qw(fetchInput evalJobs checkBuild inputsToArgs captureStdoutStderr getReleaseName getBuildLog addBuildProducts restartBuild);

sub scmPath {
    return getHydraPath . "/scm" ;
}


sub getBuildLog {
    my ($drvPath) = @_;
    my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
    return -e $logPath ? $logPath : undef;
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

sub getReleaseName {
	my ($outPath) = @_;
	
    my $releaseName;
    if (-e "$outPath/nix-support/hydra-release-name") {
        open FILE, "$outPath/nix-support/hydra-release-name" or die;
        $releaseName = <FILE>;
        chomp $releaseName;
        close FILE;
    }
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
        {srcpath => $uri, lastseen => {">", $timestamp - 30}},
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

        # Path inputs don't have a natural notion of a "revision", so
        # we simulate it by using the timestamp that we first saw this
        # path have this SHA-256 hash.  So if the contents of the path
        # changes, we get a new "revision", but if it doesn't change
        # (or changes back), we don't get a new "revision".
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
    my ($db, $project, $jobset, $name, $type, $value, $checkout) = @_;

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
        $ENV{"NIX_PREFETCH_SVN_LEAVE_DOT_SVN"} = "$checkout";
        
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("nix-prefetch-svn", $uri, $revision));
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
        push(@validBuilds, $build) if isValidPath($build->outpath);
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

    my $clonePath;
    mkpath(scmPath);
    $clonePath = scmPath . "/" . sha256_hex($uri);    

    my $stdout; my $stderr;
    if (! -d $clonePath) {
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("git", "clone", $uri, $clonePath));
        die "Error cloning git repo at `$uri':\n$stderr" unless $res;
    }

    # git pull + check rev
    chdir $clonePath or die $!;
    (my $res, $stdout, $stderr) = captureStdoutStderr(600,
        ("git", "pull"));
    die "Error pulling latest change git repo at `$uri':\n$stderr" unless $res;

    (my $res1, $stdout, $stderr) = captureStdoutStderr(600,
        ("git", "ls-remote", $clonePath, $branch));
    
    die "Cannot get head revision of Git branch '$branch' at `$uri':\n$stderr" unless $res1 ;

    my ($first) = split /\n/, $stdout;
    (my $revision, my $ref) = split ' ', $first;
    die unless $revision =~ /^[0-9a-fA-F]+$/;

    # Some simple caching: don't check a uri/branch more than once every hour, but prefer exact match on uri/branch/revision.
    my $cachedInput ;
    ($cachedInput) = $db->resultset('CachedGitInputs')->search(
        {uri => $uri, branch => $branch, revision => $revision},
        {rows => 1});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
        $revision = $cachedInput->revision;
    } else {
    
        # Then download this revision into the store.
        print STDERR "checking out Git input from $uri\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
    
        # Checked out code often wants to be able to run `git
        # describe', e.g., code that uses Gnulib's `git-version-gen'
        # script.  Thus, we leave `.git' in there.  Same for
        # Subversion (e.g., libgcrypt's build system uses that.)
        $ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "1";
    
        # Ask for a "deep clone" to allow "git describe" and similar
        # tools to work.  See
        # http://thread.gmane.org/gmane.linux.distributions.nixos/3569
        # for a discussion.
        $ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "1";
    
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("nix-prefetch-git", $uri, $revision));
        die "Cannot check out Git repository branch '$branch' at `$uri':\n$stderr" unless $res;
    
        ($sha256, $storePath) = split ' ', $stdout;
    
        txn_do($db, sub {
            $db->resultset('CachedGitInputs')->update_or_create(
                { uri => $uri
                , branch => $branch
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

sub fetchInputBazaar {
    my ($db, $project, $jobset, $name, $type, $value, $checkout) = @_;

    my $uri = $value;

    my $sha256;
    my $storePath;

    my $stdout; my $stderr;
    my $clonePath;
    mkpath(scmPath);
    $clonePath = scmPath . "/" . sha256_hex($uri);

    if (! -d $clonePath) {
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("bzr", "branch", $uri, $clonePath));
        die "Error cloning bazaar branch at `$uri':\n$stderr" unless $res;
    }

    chdir $clonePath or die $!;
    (my $res, $stdout, $stderr) = captureStdoutStderr(600,
        ("bzr", "pull"));
    die "Error pulling latest change bazaar branch at `$uri':\n$stderr" unless $res;

    # First figure out the last-modified revision of the URI.
    my @cmd = (["bzr", "revno"],
               "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);

    die "Cannot get head revision of Bazaar branch at `$uri':\n$stderr"
        unless IPC::Run::run(@cmd, \$stdout, \$stderr);
    my $revision = $stdout; chomp $revision;
    die unless $revision =~ /^\d+$/;

    (my $cachedInput) = $db->resultset('CachedBazaarInputs')->search(
        {uri => $uri, revision => $revision});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
    } else {
            
        # Then download this revision into the store.
        print STDERR "checking out Bazaar input ", $name, " from $uri revision $revision\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
        $ENV{"NIX_PREFETCH_BZR_LEAVE_DOT_BZR"} = "$checkout";
        
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("nix-prefetch-bzr", $clonePath, $revision));
        die "Cannot check out Bazaar branch `$uri':\n$stderr" unless $res;

        ($sha256, $storePath) = split ' ', $stdout;

        txn_do($db, sub {
            $db->resultset('CachedBazaarInputs')->create(
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
        };}
    
sub fetchInputHg {
    my ($db, $project, $jobset, $name, $type, $value) = @_;
    
    (my $uri, my $branch) = split ' ', $value;
    $branch = defined $branch ? $branch : "default";

    # init local hg clone

    my $stdout; my $stderr;
    my $clonePath;
    mkpath(scmPath);
    $clonePath = scmPath . "/" . sha256_hex($uri);

    if (! -d $clonePath) {
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("hg", "clone", $uri, $clonePath));
        die "Error cloning mercurial repo at `$uri':\n$stderr" unless $res;
    }

    # hg pull + check rev
    chdir $clonePath or die $!;
    (my $res, $stdout, $stderr) = captureStdoutStderr(600,
        ("hg", "pull"));
    die "Error pulling latest change mercurial repo at `$uri':\n$stderr" unless $res;

    (my $res1, $stdout, $stderr) = captureStdoutStderr(600,
        ("hg", "heads", $branch));
    die "Error getting head of $branch from `$uri':\n$stderr" unless $res1;

    $stdout =~ m/[0-9]+:([0-9A-Fa-f]{12})/;
    my $revision = $1;
    die "Could not determine head revision of branch $branch" unless $revision;
    
    my $storePath;
    my $sha256;
    (my $cachedInput) = $db->resultset('CachedHgInputs')->search(
        {uri => $uri, branch => $branch, revision => $revision});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
    } else {
        print STDERR "checking out Mercurial input from $uri $branch revision $revision\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
        
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            ("nix-prefetch-hg", $clonePath, $revision));
        die "Cannot check out Mercurial repository `$uri':\n$stderr" unless $res;

        ($sha256, $storePath) = split ' ', $stdout;

        txn_do($db, sub {
            $db->resultset('CachedHgInputs')->create(
                { uri => $uri
                , branch => $branch
                , revision => $revision
                , sha256hash => $sha256
                , storepath => $storePath
                });
            });
    }

    return 
        { type => $type
        , uri => $uri
        , branch => $branch
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        };
    
}


sub fetchInput {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

    if ($type eq "path") {
        return fetchInputPath($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "svn") {
        return fetchInputSVN($db, $project, $jobset, $name, $type, $value, 0);
    }
    elsif ($type eq "svn-checkout") {
        return fetchInputSVN($db, $project, $jobset, $name, $type, $value, 1);
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
    elsif ($type eq "hg") {
        return fetchInputHg($db, $project, $jobset, $name, $type, $value);
    }
    elsif ($type eq "bzr") {
        return fetchInputBazaar($db, $project, $jobset, $name, $type, $value, 0);
    }
    elsif ($type eq "bzr-checkout") {
        return fetchInputBazaar($db, $project, $jobset, $name, $type, $value, 1);
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
                when (["path", "build", "git", "hg", "sysbuild"]) {
                    push @res, "--arg", $input, (
                        "{ outPath = builtins.storePath " . $alt->{storePath} . "" .
                        (defined $alt->{revision} ? "; rev = \"" . $alt->{revision} . "\"" : "") .
                        (defined $alt->{version} ? "; version = \"" . $alt->{version} . "\"" : "") .
                        ";}"
                    );
                }
                when (["svn", "svn-checkout", "bzr", "bzr-checkout"]) {
                    push @res, "--arg", $input, (
                        "{ outPath = builtins.storePath " . $alt->{storePath} . "" .
                        (defined $alt->{revision} ? "; rev = " . $alt->{revision} . "" : "") .
                        ";}"
                    );
                }
            }
        }
    }

    return @res;
}

sub captureStdoutStderr {
    (my $timeout, my @cmd) = @_;
    my $res;
    my $stdin = "";
    my $stdout;
    my $stderr;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $timeout;

        $res = IPC::Run::run(\@cmd, \$stdin, \$stdout, \$stderr);
        alarm 0;
     };

     if ($@) {
        die unless $@ eq "timeout\n";   # propagate unexpected errors
        return (undef, undef, undef);
     } else {
         return ($res, $stdout, $stderr);
     }
}
    
sub evalJobs {
    my ($inputInfo, $nixExprInputName, $nixExprPath) = @_;

    my $nixExprInput = $inputInfo->{$nixExprInputName}->[0]
        or die "Cannot find the input containing the job expression.\n";
    die "Multiple alternatives for the input containing the Nix expression are not supported.\n"
        if scalar @{$inputInfo->{$nixExprInputName}} != 1;
    my $nixExprFullPath = $nixExprInput->{storePath} . "/" . $nixExprPath;
    
    (my $res, my $jobsXml, my $stderr) = captureStdoutStderr(10800,
        ("hydra_eval_jobs", $nixExprFullPath, "--gc-roots-dir", getGCRootsDir, "-j", 1, inputsToArgs($inputInfo)));
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

    my $outPath = $build->outpath;
    my $productnr = 1;

    if (-e "$outPath/nix-support/hydra-build-products") {
                open LIST, "$outPath/nix-support/hydra-build-products" or die;
                while (<LIST>) {
                    /^([\w\-]+)\s+([\w\-]+)\s+(\S+)(\s+(\S+))?$/ or next;
                    my $type = $1;
                    my $subtype = $2 eq "none" ? "" : $2;
                    my $path = $3;
                    my $defaultPath = $5;
                    next unless -e $path;

                    my $fileSize, my $sha1, my $sha256;

                    # !!! validate $path, $defaultPath

                    if (-f $path) {
                        my $st = stat($path) or die "cannot stat $path: $!";
                        $fileSize = $st->size;
                        
                        $sha1 = `nix-hash --flat --type sha1 $path`
                            or die "cannot hash $path: $?";;
                        chomp $sha1;
                    
                        $sha256 = `nix-hash --flat --type sha256 $path`
                            or die "cannot hash $path: $?";;
                        chomp $sha256;
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

            else {
                $db->resultset('BuildProducts')->create(
                    { build => $build->id
                    , productnr => $productnr++
                    , type => "nix-build"
                    , subtype => ""
                    , path => $outPath
                    , name => $build->nixname
                    });
            }
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
            $currentBuilds->{$_->id} = 0 foreach @previousBuilds;
            return;
        }
        
        my $time = time();
        
        # Nope, so add it.
        $build = $job->builds->create(
            { finished => 0
            , timestamp => $time 
            , description => $buildInfo->{description}
            , longdescription => $buildInfo->{longDescription}
            , license => $buildInfo->{license}
            , homepage => $buildInfo->{homepage}
            , maintainers => $buildInfo->{maintainers}
            , maxsilent => $buildInfo->{maxSilent}
            , timeout => $buildInfo->{timeout}
            , nixname => $buildInfo->{nixName}
            , drvpath => $drvPath
            , outpath => $outPath
            , system => $buildInfo->{system}
            , iscurrent => 1
            , nixexprinput => $jobset->nixexprinput
            , nixexprpath => $jobset->nixexprpath
            });

        
        $currentBuilds->{$build->id} = 1;
        
        if(isValidPath($outPath)) {
            print STDERR "marked as cached build ", $build->id, "\n";
        	$build->update({ finished => 1 });
            $build->create_related('buildresultinfo',
                { iscachedbuild => 1
                , buildstatus => 0
                , starttime => $time 
                , stoptime => $time 
                , logfile => getBuildLog($drvPath)
                , errormsg => ""
                , releasename => getReleaseName($outPath)
                });
            addBuildProducts($db, $build);
        } else {
            print STDERR "added to queue as build ", $build->id, "\n";
            $build->create_related('buildschedulinginfo',
                { priority => $priority
                , busy => 0
                , locker => ""
                });
        }

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


sub restartBuild {
    my ($db, $build) = @_;

    txn_do($db, sub {
        my $drvpath = $build->drvpath ;
        my $outpath = $build->outpath ;

        my $paths = "";
        foreach my $bs ($build->buildsteps) {
          $paths = $paths . " " . $bs->outpath;
        }

        my $r = `nix-store --clear-failed-paths $paths $outpath`;
        $build->update({finished => 0, timestamp => time});

        $build->resultInfo->delete;

        $db->resultset('BuildSchedulingInfo')->create(
            { id => $build->id
            , priority => 0 # don't know the original priority anymore...
            , busy => 0
            , locker => ""
            });
    });
}
