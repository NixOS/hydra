package Hydra::Controller::Release;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub release : Chained('/') PathPart('release') CaptureArgs(2) {
    my ($self, $c, $projectName, $releaseName) = @_;

    $c->stash->{project} = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{release} = $c->stash->{project}->releases->find({name => $releaseName})
        or notFound($c, "Release $releaseName doesn't exist.");
}


sub view : Chained('release') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'release.tt';
    $c->stash->{members} = [$c->stash->{release}->releasemembers->search({},
        {order_by => ["description"]})];
}


sub updateRelease {
    my ($c, $release) = @_;
    
    my $releaseName = trim $c->request->params->{name};
    error($c, "Invalid release name: $releaseName")
        unless $releaseName =~ /^$relNameRE$/;
    
    $release->update(
        { name => $releaseName
        , description => trim $c->request->params->{description}
        });

    $release->releasemembers->delete_all;
    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^member-(\d+)-description$/;
        my $buildId = $1;
        my $description = trim $c->request->params->{"member-$buildId-description"};
        $release->releasemembers->create({ build => $buildId, description => $description });
    }
}


sub edit : Chained('release') PathPart('edit') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    $c->stash->{template} = 'edit-release.tt';
    $c->stash->{members} = [$c->stash->{release}->releasemembers->search({},
        {order_by => ["description"]})];
}


sub submit : Chained('release') PathPart('submit') Args(0) {
    my ($self, $c) = @_;
    
    requireProjectOwner($c, $c->stash->{project});

    if (($c->request->params->{action} || "") eq "delete") {
        txn_do($c->model('DB')->schema, sub {
            $c->stash->{release}->delete;
        });
        $c->res->redirect($c->uri_for($c->controller('Project')->action_for('releases'),
            [$c->stash->{project}->name]));
    } else {
        txn_do($c->model('DB')->schema, sub {
            updateRelease($c, $c->stash->{release});
        });
        $c->res->redirect($c->uri_for($self->action_for("view"),
            [$c->stash->{project}->name, $c->stash->{release}->name]));
    }
}


1;
