package Hydra::Controller::Channel;

use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';


sub channel : Chained('/') PathPart('channel/custom') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $channelName) = @_;

    $c->stash->{project} = $c->model('DB::Projects')->find($projectName);

    notFound($c, "Project $projectName doesn't exist.")
        if !$c->stash->{project};

    $c->stash->{jobset} = $c->stash->{project}->jobsets->find({
        name => $jobsetName
    });

    notFound($c, "Jobset $jobsetName doesn't exist.")
        if !$c->stash->{jobset};

    my $lastSuccessful = $c->model('DB::Builds')->find(
        { 'eval.hasnewbuilds' => 1
        , project => $projectName
        , jobset => $jobsetName
        , job => $channelName
        , buildstatus => 0
        },
        { rows => 1, order_by => "eval.id desc"
        , join => { jobsetevalmembers => 'eval' }
        }
    );

    notFound($c, "Channel $channelName either doesn't exist ".
                 "or was never built successfully.")
        if !$lastSuccessful;

    $c->stash->{lastSuccessful} = $lastSuccessful;
}


sub overview : Chained('channel') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{constituents} = [
        $c->stash->{lastSuccessful}->constituents_->search(
            {}, {order_by => ["job"]}
        )
    ];

    $c->stash->{genericChannel} = 0;
    $c->stash->{template} = 'channel-contents.tt';
}


1;
