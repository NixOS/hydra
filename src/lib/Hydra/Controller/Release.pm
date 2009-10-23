package Hydra::Controller::Release;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub release : Chained('/') PathPart('release') CaptureArgs(2) {
    my ($self, $c, $projectName, $releaseName) = @_;
    #$c->stash->{project} = $project;
    #$c->stash->{release} = $view;
}


sub view : Chained('release') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'release.tt';
}


sub updateRelease {
    my ($c, $release) = @_;
    
    my $releaseName = trim $c->request->params->{name};
    error($c, "Invalid release name: $releaseName")
        unless $releaseName =~ /^[[:alpha:]][\w\-]*$/;
    
    $release->update(
        { name => $releaseName
        , description => trim $c->request->params->{description}
        });
}


1;
