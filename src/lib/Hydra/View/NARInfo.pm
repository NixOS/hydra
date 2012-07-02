package Hydra::View::NARInfo;

use strict;
use base qw/Catalyst::View/;
use File::Basename;
use Nix::Store;

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    
    $c->response->content_type('text/x-nix-narinfo'); # !!! check MIME type

    my ($deriver, $narHash, $time, $narSize, $refs) = queryPathInfo($storePath);

    my $info;
    $info .= "StorePath: $storePath\n";
    $info .= "URL: nar/" . basename $storePath. "\n";
    $info .= "Compression: bzip2\n";
    #$info .= "FileHash: sha256:$compressedHash\n";
    #$info .= "FileSize: $compressedSize\n";
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

    $c->response->body($info);

    return 1;
}

1;
