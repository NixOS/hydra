package Hydra::View::NixClosure;

use strict;
use warnings;
use base qw/Catalyst::View/;
use IO::Pipe;
use Hydra::Helper::Nix;
use Hydra::StorePath;

sub process {
    my ($self, $c) = @_;

    $c->response->content_type('application/x-nix-export');

    # `nix-store` is given full paths; the stash holds store paths.
    my $storeDir = machineLocalStore()->storeDir;
    my @storePaths = map { printStorePath($storeDir, $_) } @{$c->stash->{storePaths}};

    my $fh = IO::Handle->new();

    open($fh, "-|", "nix-store --export `nix-store -qR @storePaths` | gzip");

    $c->response->body($fh);

    return 1;
}

1;
