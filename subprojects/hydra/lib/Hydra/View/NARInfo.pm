package Hydra::View::NARInfo;

use strict;
use warnings;
use File::Basename;
use Hydra::Helper::CatalystUtils;
use MIME::Base64;
use Nix::Store;
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
sub fingerprintPath {
    my ($storePath, $narHash, $narSize, $references) = @_;
    my $storeDir = $MACHINE_LOCAL_STORE->storeDir;
    die if substr($storePath, 0, length($storeDir)) ne $storeDir;
    die if substr($narHash, 0, 7) ne "sha256:";
    # Base-32, i.e. queryPathInfo's base32 argument was set.
    die if length($narHash) != 59;
    foreach my $ref (@{$references}) {
        die if substr($ref, 0, length($storeDir)) ne $storeDir;
    }
    return "1;" . $storePath . ";" . $narHash . ";" . $narSize . ";" . join(",", @{$references});
}

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};

    $c->response->content_type('text/x-nix-narinfo'); # !!! check MIME type

    my ($deriver, $narHash, $time, $narSize, $refs) = $MACHINE_LOCAL_STORE->queryPathInfo($storePath, 1);

    my $info;
    $info .= "StorePath: $storePath\n";
    $info .= "URL: nar/" . basename $storePath. "\n";
    $info .= "Compression: xz\n";
    $info .= "NarHash: $narHash\n";
    $info .= "NarSize: $narSize\n";
    $info .= "References: " . join(" ", map { basename $_ } @{$refs}) . "\n";
    if (defined $deriver) {
        $info .= "Deriver: " . basename $deriver . "\n";
        if ($MACHINE_LOCAL_STORE->isValidPath($deriver)) {
            $info .= "System: " . $MACHINE_LOCAL_STORE->derivationSystem($deriver) . "\n";
        }
    }

    # Optionally, sign the NAR info file we just created.
    my $secretKeyFile = $c->config->{binary_cache_secret_key_file};
    if (defined $secretKeyFile) {
        my $secretKey = readFile $secretKeyFile;
        my $fingerprint = fingerprintPath($storePath, $narHash, $narSize, $refs);
        my $sig = signString($secretKey, $fingerprint);
        $info .= "Sig: $sig\n";
    }

    setCacheHeaders($c, 24 * 60 * 60);

    $c->response->body($info);

    return 1;
}

1;
