package Hydra::Plugin::DarcsInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'darcs'} = 'Darcs checkout';
}

sub fetchInput {
    my ($self, $type, $name, $uri) = @_;

    return undef if $type ne "darcs";

    my $timestamp = time;
    my $sha256;
    my $storePath;
    my $revCount;

    my $cacheDir = getSCMCacheDir . "/darcs";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);
    $uri =~ s|^file://||; # darcs wants paths, not file:// uris

    my $stdout = ""; my $stderr = ""; my $res;
    if (! -d $clonePath) {
        # Clone the repository.
        $res = run(timeout => 600,
                   cmd => ["darcs", "get", "--lazy", $uri, $clonePath],
                   dir => $ENV{"TMPDIR"});
        die "Error getting darcs repo at `$uri':\n$stderr" if $res->{status};
    }

    # Update the repository to match $uri.
    ($res, $stdout, $stderr) = captureStdoutStderr(600,
        ("darcs", "pull", "-a", "--repodir", $clonePath, "$uri"));
    die "Error fetching latest change from darcs repo at `$uri':\n$stderr" if $res;

    ($res, $stdout, $stderr) = captureStdoutStderr(600,
        ("darcs", "changes", "--last", "1", "--xml", "--repodir", $clonePath));
    die "Error getting revision ID of darcs repo at `$uri':\n$stderr" if $res;

    $stdout =~ /^<patch.*hash='([0-9a-fA-F-]+)'/sm; # sigh.
    my $revision = $1;
    die "Error obtaining revision from output: $stdout\nstderr = $stderr)" unless $revision =~ /^[0-9a-fA-F-]+$/;
    die "Error getting a revision identifier at `$uri':\n$stderr" if $res;

    # Some simple caching: don't check a uri/revision more than once.
    my $cachedInput ;
    ($cachedInput) = $self->{db}->resultset('CachedDarcsInputs')->search(
        {uri => $uri, revision => $revision},
        {rows => 1});

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
        $revision = $cachedInput->revision;
        $revCount = $cachedInput->revcount;
    } else {
        # Then download this revision into the store.
        print STDERR "checking out darcs repo $uri\n";

        my $tmpDir = File::Temp->newdir("hydra-darcs-export.XXXXXX", CLEANUP => 1, TMPDIR => 1) or die;
        (system "darcs", "get", "--lazy", $clonePath, "$tmpDir/export", "--quiet",
                "--to-match", "hash $revision") == 0
            or die "darcs export failed";
        $revCount = `darcs changes --count --repodir $tmpDir/export`; chomp $revCount;
        die "darcs changes --count failed" if $? != 0;

        system "rm", "-rf", "$tmpDir/export/_darcs";
        $storePath = addToStore("$tmpDir/export", 1, "sha256");
        $sha256 = queryPathHash($storePath);
        $sha256 =~ s/sha256://;

        txn_do($self->{db}, sub {
            $self->{db}->resultset('CachedDarcsInputs')->update_or_create(
                { uri => $uri
                , revision => $revision
                , revcount => $revCount
                , sha256hash => $sha256
                , storepath => $storePath
                });
            });
    }

    $revision =~ /^([0-9]+)/;
    my $shortRev = $1;

    return
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        , revCount => int($revCount)
        , shortRev => $shortRev
        };
}

1;
