package Hydra::View::NixClosure;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;

sub process {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/x-nix-export');

    my @storePaths = @{$c->stash->{storePaths}};

    open(OUTPUT, "nix-store --export `nix-store -qR @storePaths` | gzip |");

    my $fh = new IO::Handle;
    $fh->fdopen(fileno(OUTPUT), "r") or die;

    $c->response->body($fh);
    
    return 1;
}

1;
