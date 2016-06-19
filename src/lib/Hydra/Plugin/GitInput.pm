package Hydra::Plugin::GitInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;
use Encode;
use URI;
{ package URI::git; use base "URI::_login"; }

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'git'} = 'Git checkout';
}

sub _isHash {
    my ($rev) = @_;
    return length($rev) == 40 && $rev =~ /^[0-9a-f]+$/;
}

# Clone or update a branch of a repository into our SCM cache.
sub _cloneRepo {
    my ($self, $uri, $branch, $deepClone) = @_;

    my $cacheDir = getSCMCacheDir . "/git";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);

    my $res;
    if (! -d $clonePath) {
        # Clone everything and fetch the branch.
        $res = run(cmd => ["git", "init", $clonePath]);
        $res = run(cmd => ["git", "remote", "add", "origin", "--", $uri], dir => $clonePath) unless $res->{status};
        die "error creating git repo in `$clonePath':\n$res->{stderr}" if $res->{status};
    }

    # This command forces the update of the local branch to be in the same as
    # the remote branch for whatever the repository state is.  This command mirrors
    # only one branch of the remote repository.
    my $localBranch = _isHash($branch) ? "_hydra_tmp" : $branch;
    $res = run(cmd => ["git", "fetch", "-fu", "origin", "+$branch:$localBranch"], dir => $clonePath, timeout => 600);
    $res = run(cmd => ["git", "fetch", "-fu", "origin"], dir => $clonePath, timeout => 600) if $res->{status};
    die "error fetching latest change from git repo at `$uri':\n$res->{stderr}" if $res->{status};

    # If deepClone is defined, then we look at the content of the repository
    # to determine if this is a top-git branch.
    if (defined $deepClone) {

        # Is the target branch a topgit branch?
        $res = run(cmd => ["git", "ls-tree", "-r", "$branch", ".topgit"], dir => $clonePath);

        if ($res->{stdout} ne "") {
            # Checkout the branch to look at its content.
            $res = run(cmd => ["git", "checkout", "--force", "$branch"], dir => $clonePath);
            die "error checking out Git branch '$branch' at `$uri':\n$res->{stderr}" if $res->{status};

            # This is a TopGit branch.  Fetch all the topic branches so
            # that builders can run "tg patch" and similar.
            $res = run(cmd => ["tg", "remote", "--populate", "origin"], dir => $clonePath, timeout => 600);
            print STDERR "warning: `tg remote --populate origin' failed:\n$res->{stderr}" if $res->{status};
        }
    }

    return $clonePath;
}

sub _parseValue {
    my ($value) = @_;
    (my $uri, my $branch, my $deepClone) = split ' ', $value;
    $branch = defined $branch ? $branch : "master";
    return ($uri, $branch, $deepClone);
}

# Given a uri insert the github authentication token if the uri points to a
# resource at https://github.com/ and doesn't already specify a token.
sub _maybeAddGithubAuthentication {
  my ($config, $uriUnauthString) = @_;

  my $uriUnauth = URI->new($uriUnauthString);

  # Don't do anything if we don't have a valid token
  my $authToken = _getAuthToken($config);
  if(not defined $authToken){
    return $uriUnauthString;
  }

  if(not $uriUnauth->has_recognized_scheme){
    print STDERR "Warning: unrecognized URI scheme for uri: $uriUnauthString\n";
    return $uriUnauthString;
  }

  # Indicators for being eligible for authentication.
  my $isGithub     = $uriUnauth->host eq "github.com";
  my $isHttps      = $uriUnauth->scheme eq "https";

  if(!$isHttps){
    if($isGithub){
      print STDERR "Warning: github token will not be applied to non https uri: $uriUnauthString\n";
    }
    return $uriUnauthString;
  }

  #Don't do anything if we already have a userinfo
  return $uriUnauthString if defined $uriUnauth->userinfo;

  my $uriAuth = $uriUnauth->clone;
  $uriAuth->userinfo($authToken);

  return $uriAuth->as_string;
}

sub _getAuthToken {
  my ($config) = @_;

  # TODO: move this into a more cleanly shared field.
  if(not defined $config->{githubstatus}->{authorization}){
    return undef;
  }

  my $authorizationString = $config->{githubstatus}->{authorization};

  my ($authToken) = $authorizationString =~ m/^token ([0-9a-f]{40})$/ or do {
    print STDERR "Warning: github token not in correct form for authentication: $authorizationString\n";
    return undef;
  };

  return $authToken;
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "git";

    my ($uriUnauth, $branch, $deepClone) = _parseValue($value);

    my $uri = _maybeAddGithubAuthentication($self->{config}, $uriUnauth);

    my $clonePath = $self->_cloneRepo($uri, $branch, $deepClone);

    my $timestamp = time;
    my $sha256;
    my $storePath;

    my $revision = _isHash($branch) ? $branch
        : grab(cmd => ["git", "rev-parse", "$branch"], dir => $clonePath, chomp => 1);
    die "did not get a well-formated revision number of Git branch '$branch' at `$uri'"
        unless $revision =~ /^[0-9a-fA-F]+$/;

    # Some simple caching: don't check a uri/branch/revision more than once.
    # TODO: Fix case where the branch is reset to a previous commit.
    my $cachedInput;
    ($cachedInput) = $self->{db}->resultset('CachedGitInputs')->search(
        {uri => $uri, branch => $branch, revision => $revision},
        {rows => 1});

    addTempRoot($cachedInput->storepath) if defined $cachedInput;

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
            # script.  Thus, we leave `.git' in there.
            $ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "1";

            # Ask for a "deep clone" to allow "git describe" and similar
            # tools to work.  See
            # http://thread.gmane.org/gmane.linux.distributions.nixos/3569
            # for a discussion.
            $ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "1";
        }

        my @extraPrefetchArgs = ();
        my $authToken = _getAuthToken($self->{config});
        if(defined $authToken){
          @extraPrefetchArgs = ("--token", "$authToken");
        }

        # FIXME: Don't use nix-prefetch-git.
        ($sha256, $storePath) = split ' ', grab(cmd => ["nix-prefetch-git", $clonePath, $revision, @extraPrefetchArgs], chomp => 1);

        # FIXME: time window between nix-prefetch-git and addTempRoot.
        addTempRoot($storePath);

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
    my $revCount = scalar(split '\n', grab(cmd => ["git", "rev-list", "$revision"], dir => $clonePath));
    my $gitTag = grab(cmd => ["git", "describe", "--always", "$revision"], dir => $clonePath, chomp => 1);
    my $shortRev = grab(cmd => ["git", "rev-parse", "--short", "$revision"], dir => $clonePath, chomp => 1);

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

sub getCommits {
    my ($self, $type, $value, $rev1, $rev2) = @_;
    return [] if $type ne "git";

    return [] unless $rev1 =~ /^[0-9a-f]+$/;
    return [] unless $rev2 =~ /^[0-9a-f]+$/;

    my ($uri, $branch, $deepClone) = _parseValue($value);

    my $clonePath = getSCMCacheDir . "/git/" . sha256_hex($uri);

    my $out = grab(cmd => ["git", "log", "--pretty=format:%H%x09%an%x09%ae%x09%at", "$rev1..$rev2"], dir => $clonePath);

    my $res = [];
    foreach my $line (split /\n/, $out) {
        my ($revision, $author, $email, $date) = split "\t", $line;
        push @$res, { revision => $revision, author => decode("utf-8", $author), email => $email };
    }

    return $res;
}

1;
