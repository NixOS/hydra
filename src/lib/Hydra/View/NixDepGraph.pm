package Hydra::View::NixDepGraph;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;

sub process {
    my ($self, $c) = @_;
    
    $c->response->content_type('image/png');

    my @storePaths = @{$c->stash->{storePaths}};

    my $fh = new IO::Handle;
    
    open $fh, "nix-store --query --graph @storePaths | dot -Tpng -Gbgcolor=transparent |";

    $c->response->body($fh);
    
    return 1;
}

1;
