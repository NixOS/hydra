package Hydra::Base::Controller::NixChannel;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub closure : Chained('nix') PathPart {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixClosure';

    # !!! quick hack; this is to make HEAD requests return the right
    # MIME type.  This is set in the view as well, but the view isn't
    # called for HEAD requests.  There should be a cleaner solution...
    $c->response->content_type('application/x-nix-export');
}


sub manifest : Chained('nix') PathPart("MANIFEST") Args(0) {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixManifest';
    $c->stash->{narBase} = $c->uri_for($c->controller('Root')->action_for("nar"));
}


sub pkg : Chained('nix') PathPart Args(1) {
    my ($self, $c, $pkgName) = @_;

    my $pkg = $c->stash->{nixPkgs}->{$pkgName};

    notFound($c, "Unknown Nix package `$pkgName'.")
        unless defined $pkg;

    $c->stash->{build} = $pkg->{build};

    $c->stash->{manifestUri} = $c->uri_for($self->action_for("manifest"), $c->req->captures);

    $c->stash->{current_view} = 'NixPkg';

    $c->response->content_type('application/nix-package');
}


sub nixexprs : Chained('nix') PathPart('nixexprs.tar.bz2') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixExprs';
}


sub name {
    my ($build) = @_;
    return $build->releasename || $build->nixname;
}


sub sortPkgs {
    # Sort by name, then id.
    return sort
      { lc(name($a->{build})) cmp lc(name($b->{build}))
            or $a->{build}->id <=> $b->{build}->id } @_;
}


sub channel_contents : Chained('nix') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'channel-contents.tt';
    $c->stash->{nixPkgs} = [sortPkgs (values %{$c->stash->{nixPkgs}})];
}


1;
