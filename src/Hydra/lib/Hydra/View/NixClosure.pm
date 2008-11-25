package Hydra::View::NixClosure;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;
use POSIX qw(dup2);

sub process {
    my ( $self, $c ) = @_;
    
    $c->response->content_type('application/x-nix-export');
    $c->response->header('Content-Disposition' => 'attachment; filename=' . $c->stash->{name} . '.closure.gz');

    my $storePath = $c->stash->{storePath};

    open(OUTPUT, "nix-store --export `nix-store -qR $storePath` | gzip |");

    my $fh = new IO::Handle;
    $fh->fdopen(fileno(OUTPUT), "r") or die;

    $c->response->body($fh);
    
    return 1;
}

1;
