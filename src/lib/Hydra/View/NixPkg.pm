package Hydra::View::NixPkg;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;

sub process {
    my ($self, $c) = @_;

    $c->response->content_type('application/nix-package');

    my $build = $c->stash->{build};

    requireLocalStore($c);

    my $channelUri = $c->uri_for('/');

    # FIXME: add multiple output support
    my $s = "NIXPKG1 http://invalid.org/"
        . " " . $build->nixname . " " . $build->system
        . " " . $build->drvpath . " " . $build->buildoutputs->find({name => "out"})->path
        . " " . $channelUri;

    $c->response->body($s);

    return 1;
}

1;
