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

    $c->stash->{template} = 'job.tt';

    #getBuildStats($c, scalar $c->stash->{job}->builds);

    $c->stash->{currentBuilds} = [$c->stash->{job}->builds->search({iscurrent => 1}, { join => 'resultInfo', '+select' => ["resultInfo.releasename", "resultInfo.buildStatus"]
                                                                                     , '+as' => ["releasename", "buildStatus"], order_by => 'system' })];

    $c->stash->{lastBuilds} = 
	[ $c->stash->{job}->builds->search({ finished => 1 }, 
	    { join => 'resultInfo', 
	    , '+select' => ["resultInfo.releasename", "resultInfo.buildStatus"]
	    , '+as' => ["releasename", "buildStatus"]
	    , order_by => 'timestamp DESC', rows => 10 
	    }) ];

    $c->stash->{runningBuilds} = [
	$c->stash->{job}->builds->search(
	    { busy => 1 }, 
	    { join => ['project']
	    , order_by => ["priority DESC", "timestamp"]
            , '+select' => ['project.enabled']
	    , '+as' => ['enabled']  
	    } 
	) ];

    $c->stash->{systems} = [$c->stash->{job}->builds->search({iscurrent => 1}, {select => ["system"], distinct => 1})];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{job}->builds;
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{allJobs} = $c->stash->{job_};
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job}->name;
}


1;
