package Hydra::Plugin::MercurialInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'hg'} = 'Mercurial checkout';
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "hg";

    (my $uri, my $id) = split ' ', $value;
    $id = defined $id ? $id : "default";

    # init local hg clone

    my $stdout = ""; my $stderr = "";

    my $cacheDir = getSCMCacheDir . "/hg";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);

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
    (my $cachedInput) = $self->{db}->resultset('CachedHgInputs')->search(
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

        txn_do($self->{db}, sub {
            $self->{db}->resultset('CachedHgInputs')->update_or_create(
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

1;
