package Hydra::Base::Controller::ListBuilds;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub getJobStatus {
    my ($self, $c) = @_;
    
    my $latest = joinWithResultInfo($c, $c->stash->{jobStatus});

    my $maintainer = $c->request->params->{"maintainer"};

    $latest = $latest->search(
        defined $maintainer ? { maintainers => { like => "%$maintainer%" } } : {},
        { '+select' => ["me.statusChangeId", "me.statusChangeTime", "resultInfo.buildStatus"]
        , '+as' => ["statusChangeId", "statusChangeTime", "buildStatus"]
        , order_by => "coalesce(statusChangeTime, 0) desc"
        });

    return $latest;
}

sub jobstatus : Chained('get_builds') PathPart Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobstatus.tt';
    $c->stash->{latestBuilds} = [getJobStatus($self, $c)->all];
}


# A convenient way to see all the errors - i.e. things demanding
# attention - at a glance. 
sub errors : Chained('get_builds') PathPart Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'errors.tt';
    $c->stash->{brokenJobsets} =
        [$c->stash->{allJobsets}->search({errormsg => {'!=' => ''}})]
        if defined $c->stash->{allJobsets};
    $c->stash->{brokenJobs} =
        [$c->stash->{allJobs}->search({errormsg => {'!=' => ''}})]
        if defined $c->stash->{allJobs};
    $c->stash->{brokenBuilds} =
        [getJobStatus($self, $c)->search({'resultInfo.buildstatus' => {'!=' => 0}})];
}

    
sub all : Chained('get_builds') PathPart {
    my ($self, $c) = @_;

    $c->stash->{template} = 'all.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $nrBuilds = $c->stash->{allBuilds}->search({finished => 1})->count;

    $c->stash->{baseUri} = $c->uri_for($self->action_for("all"), $c->req->captures);

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{totalBuilds} = $nrBuilds;

    $c->stash->{builds} = [ joinWithResultInfo($c, $c->stash->{allBuilds})->search(
        { finished => 1 },
        { '+select' => ["resultInfo.buildStatus"]
        , '+as' => ["buildStatus"]
        , order_by => "timestamp DESC"
        , rows => $resultsPerPage
        , page => $page }) ];
}


sub nix : Chained('get_builds') PathPart('channel') CaptureArgs(1) {
    my ($self, $c, $channelName) = @_;
    eval {
        if ($channelName eq "latest") {
            $c->stash->{channelName} = $c->stash->{channelBaseName} . "-latest";
            getChannelData($c, scalar($c->stash->{latestSucceeded}));
        }
        #elsif ($channelName eq "all") {
        #    $c->stash->{channelName} = $c->stash->{channelBaseName} . "-all";
        #    getChannelData($c, scalar($c->stash->{allBuilds}));
        #}
        else {
            notFound($c, "Unknown channel `$channelName'.");
        }
    };
    error($c, $@) if $@;
}


# Redirect to the latest successful build.
sub latest : Chained('get_builds') PathPart('latest') {
    my ($self, $c, @rest) = @_;

    my ($latest) = joinWithResultInfo($c, $c->stash->{allBuilds})
        ->search({finished => 1, buildstatus => 0}, {order_by => ["isCurrent DESC", "timestamp DESC"]});

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;
    
    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("view_build"), [$latest->id], @rest));
}


# Redirect to the latest successful build for a specific platform.
sub latest_for : Chained('get_builds') PathPart('latest-for') {
    my ($self, $c, $system, @rest) = @_;

    notFound($c, "You need to specify a platform type in the URL.") unless defined $system;
    
    my ($latest) = joinWithResultInfo($c, $c->stash->{allBuilds})
        ->search({finished => 1, buildstatus => 0, system => $system}, {order_by => ["isCurrent DESC", "timestamp DESC"]});

    notFound($c, "There is no successful build for platform `$system' to redirect to.") unless defined $latest;
    
    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("view_build"), [$latest->id], @rest));
}


1;
