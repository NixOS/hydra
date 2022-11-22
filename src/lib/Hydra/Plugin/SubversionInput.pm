package Hydra::Plugin::SubversionInput;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use Hydra::Helper::Exec;
use Hydra::Helper::Nix;
use IPC::Run;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'svn'} = 'Subversion export';
    $inputTypes->{'svn-checkout'} = 'Subversion checkout';
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "svn" && $type ne "svn-checkout";

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
        $revision = int($stdout); $revision =~ s/\s*([0-9]+)\s*/$1/sm;
    }

    die unless $revision =~ /^\d+$/;
    $revision = int($revision);

    # Do we already have this revision in the store?
    # !!! This needs to take $checkout into account!  Otherwise "svn"
    # and "svn-checkout" inputs can get mixed up.
    (my $cachedInput) = $self->{db}->resultset('CachedSubversionInputs')->search(
        {uri => $uri, revision => $revision});

    addTempRoot($cachedInput->storepath) if defined $cachedInput;

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
    } else {

        # No, do a checkout.  The working copy is reused between
        # invocations to speed things up.
        my $wcPath = getSCMCacheDir . "/svn/" . sha256_hex($uri) . "/svn-checkout";

        print STDERR "checking out Subversion input ", $name, " from $uri revision $revision into $wcPath\n";

        (my $res, $stdout, $stderr) = captureStdoutStderr(600, "svn", "checkout", $uri, "-r", $revision, $wcPath);
        die "error checking out Subversion repo at `$uri':\n$stderr" if $res;

        if ($type eq "svn-checkout") {
            $storePath = addToStore($wcPath, 1, "sha256");
        } else {
            # Hm, if the Nix Perl bindings supported filters in
            # addToStore(), then we wouldn't need to make a copy here.
            my $tmpDir = File::Temp->newdir("hydra-svn-export.XXXXXX", CLEANUP => 1, TMPDIR => 1) or die;
            (system "svn", "export", $wcPath, "$tmpDir/source", "--quiet") == 0 or die "svn export failed";
            $storePath = addToStore("$tmpDir/source", 1, "sha256");
        }

        $sha256 = queryPathHash($storePath); $sha256 =~ s/sha256://;

        $self->{db}->txn_do(sub {
            $self->{db}->resultset('CachedSubversionInputs')->update_or_create(
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
        , revNumber => $revision
        };
}

1;
