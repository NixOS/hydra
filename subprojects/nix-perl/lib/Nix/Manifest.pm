package Nix::Manifest;

use utf8;
use strict;
use warnings;
use Nix::Config;
use Nix::Store;

our @ISA = qw(Exporter);
our @EXPORT = qw(fingerprintPath);


# Return a fingerprint of a store path to be used in binary cache
# signatures. It contains the store path, the base-32 SHA-256 hash of
# the contents of the path, and the references.
sub fingerprintPath {
    my ($storePath, $narHash, $narSize, $references) = @_;
    die if substr($storePath, 0, length($Nix::Config::storeDir)) ne $Nix::Config::storeDir;
    die if substr($narHash, 0, 7) ne "sha256:";
    # Base-32, i.e. queryPathInfo's base32 argument was set.
    die if length($narHash) != 59;
    foreach my $ref (@{$references}) {
        die if substr($ref, 0, length($Nix::Config::storeDir)) ne $Nix::Config::storeDir;
    }
    return "1;" . $storePath . ";" . $narHash . ";" . $narSize . ";" . join(",", @{$references});
}


1;
