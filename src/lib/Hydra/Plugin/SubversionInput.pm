package Hydra::Plugin::SubversionInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use Hydra::Helper::Nix;
use IPC::Run;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;

    my $properties = {
        uri      => {label => "URI", required => 1},
        revision => {label => "Revision"},
    };

    $inputTypes->{'svn'} = {
        name => 'Subversion export',
        properties => $properties,
    };

    $inputTypes->{'svn-checkout'} = {
        name => 'Subversion checkout',
        properties => $properties,
    };
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

    addTempRoot($cachedInput->store_path) if defined $cachedInput;

    if (defined $cachedInput && isValidPath($cachedInput->store_path)) {
        $storePath = $cachedInput->store_path;
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
            (system "svn", "export", $wcPath, "$tmpDir/svn-export", "--quiet") == 0 or die "svn export failed";
            $storePath = addToStore("$tmpDir/svn-export", 1, "sha256");
        }

        $sha256 = queryPathHash($storePath); $sha256 =~ s/sha256://;

        txn_do($self->{db}, sub {
            $self->{db}->resultset('CachedSubversionInputs')->update_or_create(
                { uri => $uri
                , revision => $revision
                , sha256hash => $sha256
                , store_path => $storePath
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
