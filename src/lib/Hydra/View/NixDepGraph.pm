package Hydra::View::NixDepGraph;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;

sub process {
    my ($self, $c) = @_;
    
    $c->response->content_type('image/png');

    my @storePaths = @{$c->stash->{storePaths}};

    open(OUTPUT, "nix-store --query --graph @storePaths | dot -Tpng -Gbgcolor=transparent |");

    my $fh = new IO::Handle;
    $fh->fdopen(fileno(OUTPUT), "r") or die;

    $c->response->body($fh);
    
    return 1;
}

1;
