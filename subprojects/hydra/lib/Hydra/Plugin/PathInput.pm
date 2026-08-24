package Hydra::Plugin::PathInput;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use POSIX qw(strftime);
use Hydra::Helper::Nix;
use Hydra::StorePath;
use IPC::Run3;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'path'} = 'Local path or URL';
}

sub _parseValue {
    # The input is a local path or URL, optionally followed by a
    # time period specified in seconds.
    my ($config, $value) = @_;
    my @parts = split ' ', $value;
    (my $uri, my $freq) = @parts;
    # By default don't check a path more often than every 30 seconds,
    # but the second path argument can change that value or the global
    # path_input_cache_validity_seconds configuration, in that order.
    my $timeout = defined $freq ? $freq : ($config->{path_input_cache_validity_seconds} // 30);

    return ($uri, $timeout);
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "path";

    my ($uri, $timeout) = _parseValue($self->{config}, $value);

    my $timestamp = time;
    my $sha256;
    my $storePath;

    # Some simple caching: don't check a path more than once every N seconds.
    (my $cachedInput) = $self->{db}->resultset('CachedPathInputs')->search(
        {srcpath => $uri, lastseen => {">", $timestamp - $timeout}},
        {rows => 1, order_by => "lastseen DESC"});

    if (defined $cachedInput && machineLocalStore()->isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
        $timestamp = $cachedInput->timestamp;
    } else {

        print STDERR "copying input ", $name, " from $uri\n";
        if ( $uri =~ /^\// ) {
            # `addToStore` hands back a store path already.
            $storePath = addToStore($uri);
        } else {
            # Run nix-prefetch-url with PRINT_PATH=1
            my ($stdout, $stderr);
            local $ENV{PRINT_PATH} = 1;
            run3(['nix-prefetch-url', $uri], \undef, \$stdout, \$stderr);
            die "cannot fetch $uri to the Nix store: $stderr\n" if $? != 0;
            # Get the last line (which is the full path it printed)
            my @output_lines = split /\n/, $stdout;
            my $storePathStr = $output_lines[-1] // die "nix-prefetch-url printed nothing\n";
            chomp $storePathStr;
            $storePath = parseStorePath(machineLocalStore()->storeDir, $storePathStr);
        }

        $sha256 = (machineLocalStore()->queryPathInfo($storePath, 0))[1] or die;

        ($cachedInput) = $self->{db}->resultset('CachedPathInputs')->search(
            {srcpath => $uri, sha256hash => $sha256});

        # Path inputs don't have a natural notion of a "revision", so
        # we simulate it by using the timestamp that we first saw this
        # path have this SHA-256 hash.  So if the contents of the path
        # changes, we get a new "revision", but if it doesn't change
        # (or changes back), we don't get a new "revision".
        if (!defined $cachedInput) {
            $self->{db}->txn_do(sub {
                $self->{db}->resultset('CachedPathInputs')->update_or_create(
                    { srcpath => $uri
                    , timestamp => $timestamp
                    , lastseen => $timestamp
                    , sha256hash => $sha256
                    , storepath => $storePath
                    });
                });
        } else {
            $timestamp = $cachedInput->timestamp;
            $self->{db}->txn_do(sub {
                $cachedInput->update({lastseen => time});
            });
        }
    }

    return
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => (strftime "%Y%m%d%H%M%S", gmtime($timestamp))  . ':' .  $sha256
        };
}

1;
