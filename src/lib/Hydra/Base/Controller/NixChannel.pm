package Hydra::Base::Controller::NixChannel;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Nix::Store;
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub getChannelData {
    my ($c, $checkValidity) = @_;

    my @storePaths = ();
    foreach my $build ($c->stash->{channelBuilds}->all) {
        next if $checkValidity && !isValidPath($build->outpath);
        #if (isValidPath($build->drvpath)) {
        #    # Adding `drvpath' implies adding `outpath' because of the
        #    # `--include-outputs' flag passed to `nix-store'.
        #    push @storePaths, $build->drvpath;
        #} else {
        #    push @storePaths, $build->outpath;
        #}
        push @storePaths, $build->outpath;
        my $pkgName = $build->nixname . "-" . $build->system . "-" . $build->id;
        $c->stash->{nixPkgs}->{"${pkgName}.nixpkg"} = {build => $build, name => $pkgName};
        # Put the system type in the manifest (for top-level paths) as
        # a hint to the binary patch generator.  (It shouldn't try to
        # generate patches between builds for different systems.)  It
        # would be nice if Nix stored this info for every path but it
        # doesn't.
        $c->stash->{systemForPath}->{$build->outpath} = $build->system;
    };

    $c->stash->{storePaths} = [@storePaths];
}


sub closure : Chained('nix') PathPart {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixClosure';

    getChannelData($c, 1);

    # !!! quick hack; this is to make HEAD requests return the right
    # MIME type.  This is set in the view as well, but the view isn't
    # called for HEAD requests.  There should be a cleaner solution...
    $c->response->content_type('application/x-nix-export');
}


sub manifest : Chained('nix') PathPart("MANIFEST") Args(0) {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixManifest';
    $c->stash->{narBase} = $c->uri_for($c->controller('Root')->action_for("nar"));
    getChannelData($c, 1);
}


sub pkg : Chained('nix') PathPart Args(1) {
    my ($self, $c, $pkgName) = @_;

    if (!$c->stash->{build}) {
        $pkgName =~ /-(\d+)\.nixpkg$/ or notFound($c, "Bad package name.");
        $c->stash->{build} = $c->stash->{channelBuilds}->find({ id => $1 })
            || notFound($c, "No such package in this channel.");
    }

    if (!isValidPath($c->stash->{build}->outpath)) {
        $c->response->status(410); # "Gone"
        error($c, "Build " . $c->stash->{build}->id . " is no longer available.");
    }

    $c->stash->{manifestUri} = $c->uri_for($self->action_for("manifest"), $c->req->captures);

    $c->stash->{current_view} = 'NixPkg';

    $c->response->content_type('application/nix-package');
}


sub nixexprs : Chained('nix') PathPart('nixexprs.tar.bz2') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{current_view} = 'NixExprs';
    getChannelData($c, 1);
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
    # Optimistically assume that none of the packages have been
    # garbage-collected.  That should be true for the "latest"
    # channel.
    getChannelData($c, 0);
    $c->stash->{template} = 'channel-contents.tt';
    $c->stash->{nixPkgs} = [sortPkgs (values %{$c->stash->{nixPkgs}})];
}


1;
