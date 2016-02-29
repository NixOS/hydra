package Hydra::View::NARInfo;

use File::Basename;
use Hydra::Helper::CatalystUtils;
use MIME::Base64;
use Nix::Manifest;
use Nix::Store;
use Nix::Utils;
use base qw/Catalyst::View/;
use strict;

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};

    $c->response->content_type('text/x-nix-narinfo'); # !!! check MIME type

    my ($deriver, $narHash, $time, $narSize, $refs) = queryPathInfo($storePath, 1);

    my $info;
    $info .= "StorePath: $storePath\n";
    $info .= "URL: nar/" . basename $storePath. "\n";
    $info .= "Compression: bzip2\n";
    $info .= "NarHash: $narHash\n";
    $info .= "NarSize: $narSize\n";
    $info .= "References: " . join(" ", map { basename $_ } @{$refs}) . "\n";
    if (defined $deriver) {
        $info .= "Deriver: " . basename $deriver . "\n";
        if (isValidPath($deriver)) {
            my $drv = derivationFromPath($deriver);
            $info .= "System: $drv->{platform}\n";
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
