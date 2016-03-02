package Hydra::View::NixPkg;

use strict;
use base qw/Catalyst::View/;

sub process {
    my ($self, $c) = @_;

    $c->response->content_type('application/nix-package');

    my $build = $c->stash->{build};

    # FIXME: add multiple output support
    my $s = "NIXPKG1 http://invalid.org/"
        . " " . $build->nixname . " " . $build->system
        . " " . $build->drvpath . " " . $build->buildoutputs->find({name => "out"})->path
        . " " . $c->uri_for('/');

    $c->response->body($s);

    return 1;
}

1;
