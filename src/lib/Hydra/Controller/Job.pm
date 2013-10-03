package Hydra::Controller::Job;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub job : Chained('/') PathPart('job') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $jobName) = @_;

    $c->stash->{job_} = $c->model('DB::Jobs')->search({project => $projectName, jobset => $jobsetName, name => $jobName});
    $c->stash->{job} = $c->stash->{job_}->single
        or notFound($c, "Job $projectName:$jobsetName:$jobName doesn't exist.");
    $c->stash->{project} = $c->stash->{job}->project;
    $c->stash->{jobset} = $c->stash->{job}->jobset;
}


sub overview : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;
    my $job = $c->stash->{job};

    $c->stash->{template} = 'job.tt';

    $c->stash->{lastBuilds} =
        [ $job->builds->search({ finished => 1 },
            { order_by => 'id DESC', rows => 10, columns => [@buildListColumns] }) ];

    $c->stash->{queuedBuilds} = [
        $job->builds->search(
            { finished => 0 },
            { join => ['project']
            , order_by => ["priority DESC", "id"]
            , '+select' => ['project.enabled']
            , '+as' => ['enabled']
            }
        ) ];

    # If this is an aggregate job, then get its constituents.
    my @constituents = $c->model('DB::Builds')->search(
        { aggregate => { -in => $job->builds->search({}, { columns => ["id"], order_by => "id desc", rows => 15 })->as_query } },
        { join => 'aggregateconstituents_constituents', 
          columns => ['id', 'job', 'finished', 'buildstatus'],
          +select => ['aggregateconstituents_constituents.aggregate'],
          +as => ['aggregate']
        });

    my $aggregates = {};
    my %constituentJobs;
    foreach my $b (@constituents) {
        my $jobName = $b->get_column('job');
        $aggregates->{$b->get_column('aggregate')}->{constituents}->{$jobName} =
            { id => $b->id, finished => $b->finished, buildstatus => $b->buildstatus };
        $constituentJobs{$jobName} = 1;
    }

    foreach my $agg (keys %$aggregates) {
        # FIXME: could be done in one query.
        $aggregates->{$agg}->{build} = 
            $c->model('DB::Builds')->find({id => $agg}, {columns => [@buildListColumns]}) or die;
    }

    $c->stash->{aggregates} = $aggregates;
    $c->stash->{constituentJobs} = [sort (keys %constituentJobs)];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{job}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job}->name;
}


1;
