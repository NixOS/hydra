package Hydra::View::NixNAR;

use strict;
use base qw/Catalyst::View/;

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    
    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type

    my $fh = new IO::Handle;
    
    open $fh, "nix-store --dump '$storePath' | bzip2 |";

    $c->response->body($fh);

    return 1;
}

1;
