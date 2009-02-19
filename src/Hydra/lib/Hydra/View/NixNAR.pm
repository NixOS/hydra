package Hydra::View::NixNAR;

use strict;
use base qw/Catalyst::View/;

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    
    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type

    open(OUTPUT, "nix-store --dump '$storePath' | bzip2 |");

    my $fh = new IO::Handle;
    $fh->fdopen(fileno(OUTPUT), "r") or die;

    $c->response->body($fh);

    undef $fh;
    
    return 1;
}

1;
