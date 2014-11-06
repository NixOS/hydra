package Hydra::View::NARInfo;

use strict;
use base qw/Catalyst::View/;
use File::Basename;
use Nix::Store;
use Nix::Crypto;
use Hydra::Helper::CatalystUtils;

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
    my $privateKeyFile = $c->config->{binary_cache_private_key_file};
    my $keyName = $c->config->{binary_cache_key_name};

    if (defined $privateKeyFile && defined $keyName) {
        my $sig = signString($privateKeyFile, $info);
        $info .= "Signature: 1;$keyName;$sig\n";
    }

    setCacheHeaders($c, 24 * 60 * 60);

    $c->response->body($info);

    return 1;
}

1;
