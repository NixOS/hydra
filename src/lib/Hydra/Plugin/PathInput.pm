package Hydra::Plugin::PathInput;

use strict;
use parent 'Hydra::Plugin';
use POSIX qw(strftime);
use Hydra::Helper::Nix;
use Nix::Store;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'path'} = {
        name => 'Local path',
        singleton => {},
    };
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "path";

    my $uri = $value;

    my $timestamp = time;
    my $sha256;
    my $storePath;

    # Some simple caching: don't check a path more than once every N seconds.
    (my $cachedInput) = $self->{db}->resultset('CachedPathInputs')->search(
        {src_path => $uri, last_seen => {">", $timestamp - 30}},
        {rows => 1, order_by => "last_seen DESC"});

    if (defined $cachedInput && isValidPath($cachedInput->store_path)) {
        $storePath = $cachedInput->store_path;
        $sha256 = $cachedInput->sha256hash;
        $timestamp = $cachedInput->timestamp;
    } else {

        print STDERR "copying input ", $name, " from $uri\n";
        if ( $uri =~ /^\// ) {
            $storePath = `nix-store --add "$uri"`
                or die "cannot copy path $uri to the Nix store.\n";
        } else {
            $storePath = `PRINT_PATH=1 nix-prefetch-url "$uri" | tail -n 1`
                or die "cannot fetch $uri to the Nix store.\n";
        }
        chomp $storePath;

        $sha256 = (queryPathInfo($storePath, 0))[1] or die;

        ($cachedInput) = $self->{db}->resultset('CachedPathInputs')->search(
            {src_path => $uri, sha256hash => $sha256});

        # Path inputs don't have a natural notion of a "revision", so
        # we simulate it by using the timestamp that we first saw this
        # path have this SHA-256 hash.  So if the contents of the path
        # changes, we get a new "revision", but if it doesn't change
        # (or changes back), we don't get a new "revision".
        if (!defined $cachedInput) {
            txn_do($self->{db}, sub {
                $self->{db}->resultset('CachedPathInputs')->update_or_create(
                    { src_path => $uri
                    , timestamp => $timestamp
                    , last_seen => $timestamp
                    , sha256hash => $sha256
                    , store_path => $storePath
                    });
                });
        } else {
            $timestamp = $cachedInput->timestamp;
            txn_do($self->{db}, sub {
                $cachedInput->update({last_seen => time});
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

1;
