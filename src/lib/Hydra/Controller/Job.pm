package Hydra::Controller::Job;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub job : Chained('/project/project') PathPart('job') CaptureArgs(1) {
    my ($self, $c, $jobName) = @_;

    $c->stash->{jobName} = $jobName;

    # !!! nothing to do here yet, since we don't have a jobs table.
}


sub index : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->go($self->action_for("all"));
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} =
        $c->stash->{curProject}->builds->search({attrName => $c->stash->{jobName}});
    $c->stash->{channelBaseName} =
        $c->stash->{curProject}->name . "-" . $c->stash->{jobName};
}


1;
