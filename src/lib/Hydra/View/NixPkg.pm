package Hydra::View::NixPkg;

use strict;
use base qw/Catalyst::View/;

sub process {
    my ($self, $c) = @_;

    $c->response->content_type('application/nix-package');

    my $build = $c->stash->{build};

    my $s = "NIXPKG1 " . $c->stash->{manifestUri}
        . " " . $build->nixname . " " . $build->system
        . " " . $build->drvpath . " " . $build->outpath
	. " " . $c->uri_for('/');
    
    $c->response->body($s);

    return 1;
}

1;
