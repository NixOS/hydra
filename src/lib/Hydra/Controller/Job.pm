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


sub overview : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'job.tt';

    getBuildStats($c, scalar $c->stash->{job}->builds);

    $c->stash->{systems} = [$c->stash->{job}->builds->search({}, {select => ["system"], distinct => 1})];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{job}->builds;
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job}->name;
}


1;
