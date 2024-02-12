package Hydra::Base::Controller::NixChannel;

use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use List::SomeUtils qw(any);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub getChannelData {
    my ($c, $checkValidity) = @_;

    requireLocalStore($c);

    my @storePaths = ();
    $c->stash->{nixPkgs} = [];

    my @builds = $c->stash->{channelBuilds}->all;

    for (my $n = 0; $n < scalar @builds; ) {
        # Since channelData is a join of Builds and BuildOutputs, we
        # need to gather the rows that belong to a single build.
        my $build = $builds[$n++];
        my @outputs = ($build);
        push @outputs, $builds[$n++] while $n < scalar @builds && $builds[$n]->id == $build->id;
        @outputs = grep { $_->get_column("outpath") } @outputs;

        my $outputs = {};
        foreach my $output (@outputs) {
            my $outPath = $output->get_column("outpath");
            next if $checkValidity && !$BINARY_CACHE_STORE->isValidPath($outPath);
            $outputs->{$output->get_column("outname")} = $outPath;
            push @storePaths, $outPath;
            # Put the system type in the manifest (for top-level
            # paths) as a hint to the binary patch generator.  (It
            # shouldn't try to generate patches between builds for
            # different systems.)  It would be nice if Nix stored this
            # info for every path but it doesn't.
            $c->stash->{systemForPath}->{$outPath} = $build->system;
        }

        next if !%$outputs;

        my $pkgName = $build->nixname . "-" . $build->system . "-" . $build->id;
        push @{$c->stash->{nixPkgs}}, { build => $build, name => $pkgName, outputs => $outputs };
    }

    $c->stash->{storePaths} = [@storePaths];
}


sub closure : Chained('nix') PathPart {
    my ($self, $c) = @_;

    requireLocalStore($c);

    $c->stash->{current_view} = 'NixClosure';

    getChannelData($c, 1);

    # FIXME: get the closure of the selected path only.

    # !!! quick hack; this is to make HEAD requests return the right
    # MIME type.  This is set in the view as well, but the view isn't
    # called for HEAD requests.  There should be a cleaner solution...
    $c->response->content_type('application/x-nix-export');
}


sub manifest : Chained('nix') PathPart("MANIFEST") Args(0) {
    my ($self, $c) = @_;
    requireLocalStore($c);
    $c->stash->{current_view} = 'NixManifest';
    $c->stash->{narBase} = $c->uri_for($c->controller('Root')->action_for("nar"));
    getChannelData($c, 1);
}


sub nixexprs : Chained('nix') PathPart('nixexprs.tar.bz2') Args(0) {
    my ($self, $c) = @_;
    requireLocalStore($c);
    $c->stash->{current_view} = 'NixExprs';
    getChannelData($c, 1);
}


sub binary_cache_url : Chained('nix') PathPart('binary-cache-url') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{'plain'} = { data => $c->uri_for('/') };
    $c->response->content_type('text/plain');
    $c->forward('Hydra::View::Plain');
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
    requireLocalStore($c);
    # Optimistically assume that none of the packages have been
    # garbage-collected.  That should be true for the "latest"
    # channel.
    getChannelData($c, 0);
    $c->stash->{genericChannel} = 1;
    $c->stash->{template} = 'channel-contents.tt';
    $c->stash->{nixPkgs} = [sortPkgs @{$c->stash->{nixPkgs}}];
}


1;
