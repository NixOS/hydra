package Hydra::Controller::Job;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub job : Chained('/') PathPart('job') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $jobName) = @_;

    $c->stash->{job} = $c->model('DB::Jobs')->find({project => $projectName, jobset => $jobsetName, name => $jobName})
        or notFound($c, "Job $projectName:$jobsetName:$jobName doesn't exist.");
    $c->stash->{project} = $c->stash->{job}->project;
    $c->stash->{jobset} = $c->stash->{job}->jobset;
}


sub index : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->go($self->action_for("all"));
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{job}->builds;
    #$c->stash->{allJobs} = # !!! horribly hacky
    #    $c->stash->{job}->jobset->jobs->search({name => $c->stash->{job}->name});
    $c->stash->{allJobs} = [$c->stash->{job}];
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job}->name;
}


1;
