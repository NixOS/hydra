package Hydra::Plugin::BazaarInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'bzr'} = 'Bazaar export';
    $inputTypes->{'bzr-checkout'} = 'Bazaar checkout';
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "bzr" && $type ne "bzr-checkout";

    my $uri = $value;

    my $sha256;
    my $storePath;

    my $stdout; my $stderr;

    my $cacheDir = getSCMCacheDir . "/bzr";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);

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

    (my $cachedInput) = $self->{db}->resultset('CachedBazaarInputs')->search(
        {uri => $uri, revision => $revision});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
    } else {

        # Then download this revision into the store.
        print STDERR "checking out Bazaar input ", $name, " from $uri revision $revision\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
        $ENV{"NIX_PREFETCH_BZR_LEAVE_DOT_BZR"} = $type eq "bzr-checkout" ? "1" : "0";

        (my $res, $stdout, $stderr) = captureStdoutStderr(600,
            "nix-prefetch-bzr", $clonePath, $revision);
        die "cannot check out Bazaar branch `$uri':\n$stderr" if $res;

        ($sha256, $storePath) = split ' ', $stdout;

        txn_do($self->{db}, sub {
            $self->{db}->resultset('CachedBazaarInputs')->create(
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

1;
