package Hydra::View::NARInfo;

use strict;
use warnings;
use Hydra::Helper::CatalystUtils;
use MIME::Base64;
use Nix::Store;
use Hydra::StorePath;
use Hydra::Helper::Nix;
use base qw/Catalyst::View/;

sub readFile {
    local $/ = undef;
    my ($fn) = @_;
    open my $fh, "<", $fn or die "cannot open file '$fn': $!";
    my $s = <$fh>;
    close $fh or die;
    return $s;
}

# Return a fingerprint of a store path to be used in binary cache
# signatures. It contains the store path, the base-32 SHA-256 hash of
# the contents of the path, and the references.
#
# These are full paths: the fingerprint is what gets signed, so the store
# directory is part of it. That they are in the store no longer needs
# checking, being a property of the type.
sub fingerprintPath {
    my ($storeDir, $storePath, $narHash, $narSize, $references) = @_;
    die if substr($narHash, 0, 7) ne "sha256:";
    # Base-32, i.e. queryPathInfo's base32 argument was set.
    die if length($narHash) != 59;
    return "1;" . printStorePath($storeDir, $storePath) . ";" . $narHash . ";" . $narSize . ";"
        . join(",", map { printStorePath($storeDir, $_) } @{$references});
}

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    my $storeDir = $c->model('DB')->schema->storeDir;

    $c->response->content_type('text/x-nix-narinfo'); # !!! check MIME type

    my ($deriver, $narHash, $time, $narSize, $refs) = machineLocalStore()->queryPathInfo($storePath, 1);

    # `StorePath` is a full path; `URL`, `References` and `Deriver` are bare
    # store paths, which is what these now stringify to.
    my $info;
    $info .= "StorePath: " . printStorePath($storeDir, $storePath) . "\n";
    $info .= "URL: nar/$storePath\n";
    $info .= "Compression: xz\n";
    $info .= "NarHash: $narHash\n";
    $info .= "NarSize: $narSize\n";
    $info .= "References: " . join(" ", @{$refs}) . "\n";
    if (defined $deriver) {
        $info .= "Deriver: $deriver\n";
        if (machineLocalStore()->isValidPath($deriver)) {
            $info .= "System: " . machineLocalStore()->derivationSystem($deriver) . "\n";
        }
    }

    # Optionally, sign the NAR info file we just created.
    my $secretKeyFile = $c->config->{binary_cache_secret_key_file};
    if (defined $secretKeyFile) {
        my $secretKey = readFile $secretKeyFile;
        my $fingerprint = fingerprintPath($storeDir, $storePath, $narHash, $narSize, $refs);
        my $sig = signString($secretKey, $fingerprint);
        $info .= "Sig: $sig\n";
    }

    setCacheHeaders($c, 24 * 60 * 60);

    $c->response->body($info);

    return 1;
}

1;
