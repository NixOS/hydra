package Hydra::Controller::Job;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub job : Chained('/') PathPart('job') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $jobName) = @_;

    # !!! cut&paste from Project::project.
    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{curProject} = $project;
    
    $c->stash->{jobset} = $project->jobsets->find({name => $jobsetName})
        or notFound($c, "Jobset $jobsetName doesn't exist.");
    
    $c->stash->{jobName} = $jobName;
}


sub index : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->go($self->action_for("all"));
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} =
        $c->stash->{jobset}->builds->search({job => $c->stash->{jobName}});
    $c->stash->{channelBaseName} =
        $c->stash->{curProject}->name . "-" . $c->stash->{jobName};
}


1;
