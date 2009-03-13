package Hydra::Controller::Jobset;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub jobset : Chained('/') PathPart('jobset') CaptureArgs(2) {
    my ($self, $c, $projectName, $jobsetName) = @_;

    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{project} = $project;
    
    $c->stash->{jobset} = $project->jobsets->find({name => $jobsetName})
        or notFound($c, "Jobset $jobsetName doesn't exist.");
}


sub index : Chained('jobset') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->go($self->action_for("all"));
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('jobset') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds;
    $c->stash->{allJobs} = $c->stash->{jobset}->jobs;
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name;
}


1;
