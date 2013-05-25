package Hydra::Plugin::GitInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'git'} = 'Git checkout';
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "git";

    (my $uri, my $branch, my $deepClone) = split ' ', $value;
    $branch = defined $branch ? $branch : "master";

    my $timestamp = time;
    my $sha256;
    my $storePath;

    my $cacheDir = getSCMCacheDir . "/git";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);

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
    ($cachedInput) = $self->{db}->resultset('CachedGitInputs')->search(
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

        txn_do($self->{db}, sub {
            $self->{db}->resultset('CachedGitInputs')->update_or_create(
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

1;
