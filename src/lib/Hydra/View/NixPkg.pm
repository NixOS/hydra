package Hydra::View::NixPkg;

use strict;
use base qw/Catalyst::View/;

sub process {
    my ($self, $c) = @_;

    $c->response->content_type('application/nix-package');

    my $build = $c->stash->{build};

    my $storeMode = $c->config->{store_mode} // "direct";
    my $channelUri =
        $storeMode eq "direct" ? $c->uri_for('/')
        : $storeMode eq "s3-binary-cache" ?
          ($c->config->{binary_cache_public_uri} // ("https://" . $c->config->{binary_cache_s3_bucket} . ".s3.amazonaws.com/"))
        : die "Not supported.\n";

    # FIXME: add multiple output support
    my $s = "NIXPKG1 http://invalid.org/"
        . " " . $build->nixname . " " . $build->system
        . " " . $build->drvpath . " " . $build->buildoutputs->find({name => "out"})->path
        . " " . $channelUri;

    $c->response->body($s);

    return 1;
}

1;
