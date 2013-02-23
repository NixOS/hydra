package Hydra::Helper::AddBuilds;

use strict;
use feature 'switch';
use XML::Simple;
use POSIX qw(strftime);
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
    fetchInput evalJobs checkBuild inputsToArgs captureStdoutStderr
    getReleaseName addBuildProducts restartBuild scmPath
    getPrevJobsetEval
);


sub scmPath {
    return Hydra::Model::DB::getHydraPath . "/scm" ;
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


sub fetchInputPath {
    my ($db, $project, $jobset, $name, $value) = @_;

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
            or die "cannot copy path $uri to the Nix store.\n";
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
                $db->resultset('CachedPathInputs')->update_or_create(
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
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp)
        };
}


sub fetchInputSVN {
    my ($db, $project, $jobset, $name, $value, $checkout) = @_;

    # Allow users to specify a revision number next to the URI.
    my ($uri, $revision) = split ' ', $value;

    my $sha256;
    my $storePath;
    my $stdout; my $stderr;

    unless (defined $revision) {
        # First figure out the last-modified revision of the URI.
        my @cmd = (["svn", "ls", "-v", "--depth", "empty", $uri],
                   "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);
        IPC::Run::run(@cmd, \$stdout, \$stderr);
        die "cannot get head revision of Subversion repository at `$uri':\n$stderr" if $?;
        $revision = $stdout; $revision =~ s/\s*([0-9]+)\s*/$1/sm;
    }

    die unless $revision =~ /^\d+$/;

    # Do we already have this revision in the store?
    # !!! This needs to take $checkout into account!  Otherwise "svn"
    # and "svn-checkout" inputs can get mixed up.
    (my $cachedInput) = $db->resultset('CachedSubversionInputs')->search(
        {uri => $uri, revision => $revision});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
    } else {

        # No, do a checkout.  The working copy is reused between
        # invocations to speed things up.
        my $wcPath = scmPath . "/svn/" . sha256_hex($uri) . "/svn-checkout";

        print STDERR "checking out Subversion input ", $name, " from $uri revision $revision into $wcPath\n";

        (my $res, $stdout, $stderr) = captureStdoutStderr(600, "svn", "checkout", $uri, "-r", $revision, $wcPath);
        die "error checking out Subversion repo at `$uri':\n$stderr" if $res;

        if ($checkout) {
            $storePath = addToStore($wcPath, 1, "sha256");
        } else {
            # Hm, if the Nix Perl bindings supported filters in
            # addToStore(), then we wouldn't need to make a copy here.
            my $tmpDir = File::Temp->newdir("hydra-svn-export.XXXXXX", CLEANUP => 1, TMPDIR => 1) or die;
            (system "svn", "export", $wcPath, "$tmpDir/svn-export", "--quiet") == 0 or die "svn export failed";
            $storePath = addToStore("$tmpDir/svn-export", 1, "sha256");
        }

        $sha256 = queryPathHash($storePath); $sha256 =~ s/sha256://;

        txn_do($db, sub {
            $db->resultset('CachedSubversionInputs')->update_or_create(
                { uri => $uri
                , revision => $revision
                , sha256hash => $sha256
                , storepath => $storePath
                });
            });
    }

    return
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        };
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
        push(@validBuilds, $build) if !isValidPath(getMainOutput($build)->path);
    }

    if (scalar(@validBuilds) == 0) {
        print STDERR "input `", $name, "': no previous build available\n";
        return undef;
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


sub fetchInputGit {
    my ($db, $project, $jobset, $name, $value) = @_;

    (my $uri, my $branch, my $deepClone) = split ' ', $value;
    $branch = defined $branch ? $branch : "master";

    my $timestamp = time;
    my $sha256;
    my $storePath;

    mkpath(scmPath);
    my $clonePath = scmPath . "/" . sha256_hex($uri);

    my $stdout = ""; my $stderr = ""; my $res;
    if (! -d $clonePath) {
        # Clone everything and fetch the branch.
        # TODO: Optimize the first clone by using "git init $clonePath" and "git remote add origin $uri".
        ($res, $stdout, $stderr) = captureStdoutStderr(600, "git", "clone", "--branch", $branch, $uri, $clonePath);
        die "error cloning git repo at `$uri':\n$stderr" if $res;
    }

    chdir $clonePath or die $!; # !!! urgh, shouldn't do a chdir

    # This command force the update of the local branch to be in the same as
    # the remote branch for whatever the repository state is.  This command mirror
    # only one branch of the remote repository.
    ($res, $stdout, $stderr) = captureStdoutStderr(600,
        "git", "fetch", "-fu", "origin", "+$branch:$branch");
    ($res, $stdout, $stderr) = captureStdoutStderr(600,
        "git", "fetch", "-fu", "origin") if $res;
    die "error fetching latest change from git repo at `$uri':\n$stderr" if $res;

    ($res, $stdout, $stderr) = captureStdoutStderr(600,
        ("git", "rev-parse", "$branch"));
    die "error getting revision number of Git branch '$branch' at `$uri':\n$stderr" if $res;

    my ($revision) = split /\n/, $stdout;
    die "error getting a well-formated revision number of Git branch '$branch' at `$uri':\n$stdout"
        unless $revision =~ /^[0-9a-fA-F]+$/;

    my $ref = "refs/heads/$branch";

    # If deepClone is defined, then we look at the content of the repository
    # to determine if this is a top-git branch.
    if (defined $deepClone) {

        # Checkout the branch to look at its content.
        ($res, $stdout, $stderr) = captureStdoutStderr(600, "git", "checkout", "$branch");
        die "error checking out Git branch '$branch' at `$uri':\n$stderr" if $res;

        if (-f ".topdeps") {
            # This is a TopGit branch.  Fetch all the topic branches so
            # that builders can run "tg patch" and similar.
            ($res, $stdout, $stderr) = captureStdoutStderr(600,
                "tg", "remote", "--populate", "origin");
            print STDERR "warning: `tg remote --populate origin' failed:\n$stderr" if $res;
        }
    }

    # Some simple caching: don't check a uri/branch/revision more than once.
    # TODO: Fix case where the branch is reset to a previous commit.
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
        print STDERR "checking out Git branch $branch from $uri\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
        $ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "0";
        $ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "";

        if (defined $deepClone) {
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
        }

        ($res, $stdout, $stderr) = captureStdoutStderr(600, "nix-prefetch-git", $clonePath, $revision);
        die "cannot check out Git repository branch '$branch' at `$uri':\n$stderr" if $res;

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

    # For convenience in producing readable version names, pass the
    # number of commits in the history of this revision (‘revCount’)
    # the output of git-describe (‘gitTag’), and the abbreviated
    # revision (‘shortRev’).
    my $revCount = `git rev-list $revision | wc -l`; chomp $revCount;
    die "git rev-list failed" if $? != 0;
    my $gitTag = `git describe --always $revision`; chomp $gitTag;
    die "git describe failed" if $? != 0;
    my $shortRev = `git rev-parse --short $revision`; chomp $shortRev;
    die "git rev-parse failed" if $? != 0;

    return
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        , revCount => int($revCount)
        , gitTag => $gitTag
        , shortRev => $shortRev
        };
}


sub fetchInputBazaar {
    my ($db, $project, $jobset, $name, $value, $checkout) = @_;

    my $uri = $value;

    my $sha256;
    my $storePath;

    my $stdout; my $stderr;

    mkpath(scmPath);
    my $clonePath = scmPath . "/" . sha256_hex($uri);

    if (! -d $clonePath) {
        (my $res, $stdout, $stderr) = captureStdoutStderr(600, "bzr", "branch", $uri, $clonePath);
        die "error cloning bazaar branch at `$uri':\n$stderr" if $res;
    }

    chdir $clonePath or die $!;
    (my $res, $stdout, $stderr) = captureStdoutStderr(600, "bzr", "pull");
    die "error pulling latest change bazaar branch at `$uri':\n$stderr" if $res;

    # First figure out the last-modified revision of the URI.
    my @cmd = (["bzr", "revno"], "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);

    IPC::Run::run(@cmd, \$stdout, \$stderr);
    die "cannot get head revision of Bazaar branch at `$uri':\n$stderr" if $?;
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
            "nix-prefetch-bzr", $clonePath, $revision);
        die "cannot check out Bazaar branch `$uri':\n$stderr" if $res;

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
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        };
}


sub fetchInputHg {
    my ($db, $project, $jobset, $name, $value) = @_;

    (my $uri, my $id) = split ' ', $value;
    $id = defined $id ? $id : "default";

    # init local hg clone

    my $stdout = ""; my $stderr = "";

    mkpath(scmPath);
    my $clonePath = scmPath . "/" . sha256_hex($uri);

    if (! -d $clonePath) {
        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            "hg", "clone", $uri, $clonePath);
        die "error cloning mercurial repo at `$uri':\n$stderr" if $res;
    }

    # hg pull + check rev
    chdir $clonePath or die $!;
    (my $res, $stdout, $stderr) = captureStdoutStderr(600, "hg", "pull");
    die "error pulling latest change mercurial repo at `$uri':\n$stderr" if $res;

    (my $res1, $stdout, $stderr) = captureStdoutStderr(600,
        "hg", "log", "-r", $id, "--template", "{node|short} {rev} {branch}");
    die "error getting branch and revision of $id from `$uri':\n$stderr" if $res1;

    my ($revision, $revCount, $branch) = split ' ', $stdout;

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
            "nix-prefetch-hg", $clonePath, $revision);
        die "cannot check out Mercurial repository `$uri':\n$stderr" if $res;

        ($sha256, $storePath) = split ' ', $stdout;

        txn_do($db, sub {
            $db->resultset('CachedHgInputs')->update_or_create(
                { uri => $uri
                , branch => $branch
                , revision => $revision
                , sha256hash => $sha256
                , storepath => $storePath
                });
            });
    }

    return
        { uri => $uri
        , branch => $branch
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        , revCount => int($revCount)
        };
}


sub fetchInput {
    my ($db, $project, $jobset, $name, $type, $value) = @_;
    my @inputs;

    if ($type eq "path") {
        push @inputs, fetchInputPath($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "svn") {
        push @inputs, fetchInputSVN($db, $project, $jobset, $name, $value, 0);
    }
    elsif ($type eq "svn-checkout") {
        push @inputs, fetchInputSVN($db, $project, $jobset, $name, $value, 1);
    }
    elsif ($type eq "build") {
        push @inputs, fetchInputBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "sysbuild") {
        push @inputs, fetchInputSystemBuild($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "git") {
        push @inputs, fetchInputGit($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "hg") {
        push @inputs, fetchInputHg($db, $project, $jobset, $name, $value);
    }
    elsif ($type eq "bzr") {
        push @inputs, fetchInputBazaar($db, $project, $jobset, $name, $value, 0);
    }
    elsif ($type eq "bzr-checkout") {
        push @inputs, fetchInputBazaar($db, $project, $jobset, $name, $value, 1);
    }
    elsif ($type eq "string") {
        die unless defined $value;
        push @inputs, { value => $value };
    }
    elsif ($type eq "boolean") {
        die unless defined $value && ($value eq "true" || $value eq "false");
        push @inputs, { value => $value };
    }
    else {
        die "input `" . $name . "' has unknown type `$type'.";
    }

    foreach my $input (@inputs) {
        $input->{type} = $type if defined $input;
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
                when (["path", "build", "git", "hg", "sysbuild"]) {
                    push @res, "--arg", $input, buildInputToString($exprType, $alt);
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
    my ($timeout, @cmd) = @_;
    my $stdin = "";
    my $stdout;
    my $stderr;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $timeout;
        IPC::Run::run(\@cmd, \$stdin, \$stdout, \$stderr);
        alarm 0;
    };

    if ($@) {
        die unless $@ eq "timeout\n"; # propagate unexpected errors
        return (-1, "", "timeout\n");
    } else {
        return ($?, $stdout, $stderr);
    }
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
    die "cannot evaluate the Nix expression containing the jobs:\n$stderr" if $res;

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
                /^([\w\-]+)\s+([\w\-]+)\s+(\S+)(\s+(\S+))?$/ or next;
                my $type = $1;
                my $subtype = $2 eq "none" ? "" : $2;
                my $path = File::Spec->canonpath($3);
                my $defaultPath = $5;

                # Ensure that the path exists and points into the Nix store.
                next unless File::Spec->file_name_is_absolute($path);
                next if $path =~ /\/\.\./; # don't go up
                next unless substr($path, 0, length($storeDir)) eq $storeDir;
                next unless -e $path;
                next if -l $path;

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
            , timestamp => time
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
