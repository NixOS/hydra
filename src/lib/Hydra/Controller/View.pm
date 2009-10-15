package Hydra::Controller::View;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub getView {
    my ($c, $projectName, $viewName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{project} = $project;

    (my $view) = $c->model('DB::Views')->find($projectName, $viewName);
    notFound($c, "View $viewName doesn't exist.") if !defined $view;
    $c->stash->{view} = $view;

    (my $primaryJob) = $view->viewjobs->search({isprimary => 1});
    #die "View $viewName doesn't have a primary job." if !defined $primaryJob;

    my $jobs = [$view->viewjobs->search({},
        {order_by => ["isprimary DESC", "job", "attrs"]})];

    $c->stash->{jobs} = $jobs;

    return ($project, $view, $primaryJob, $jobs);
}


sub updateReleaseSet {
    my ($c, $releaseSet) = @_;
    
    my $releaseSetName = trim $c->request->params->{name};
    error($c, "Invalid release set name: $releaseSetName")
        unless $releaseSetName =~ /^[[:alpha:]][\w\-]*$/;
    
    $releaseSet->update(
        { name => $releaseSetName
        , description => trim $c->request->params->{description} });

    $releaseSet->releasesetjobs->delete_all;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^job-(\d+)-name$/;
        my $baseName = $1;

        my $name = trim $c->request->params->{"job-$baseName-name"};
        my $description = trim $c->request->params->{"job-$baseName-description"};
        my $attrs = trim $c->request->params->{"job-$baseName-attrs"};

        $name =~ /^([\w\-]+):([\w\-]+)$/ or error($c, "Invalid job name: $name");
        my $jobsetName = $1;
        my $jobName = $2;

        error($c, "Jobset `$jobsetName' doesn't exist.")
            unless $releaseSet->project->jobsets->find({name => $jobsetName});

        # !!! We could check whether the job exists, but that would
        # require the scheduler to have seen the job, which may not be
        # the case.
        
        $releaseSet->releasesetjobs->create(
            { jobset => $jobsetName
            , job => $jobName
            , description => $description
            , attrs => $attrs
            , isprimary => $c->request->params->{"primary"} eq $baseName ? 1 : 0
            });
    }

    error($c, "There must be one primary job.")
        if $releaseSet->releasesetjobs->search({isprimary => 1})->count != 1;
}


sub view : Chained('/') PathPart('view') CaptureArgs(2) {
    my ($self, $c, $projectName, $viewName) = @_;
    my ($project, $view, $primaryJob, $jobs) = getView($c, $projectName, $viewName);
    $c->stash->{project} = $project;
    $c->stash->{view} = $view;
    $c->stash->{primaryJob} = $primaryJob;
    $c->stash->{jobs} = $jobs;
}


sub view_view : Chained('view') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'view.tt';

    my $resultsPerPage = 10;
    my $page = int($c->req->param('page')) || 1;

    my @results = ();
    push @results, getRelease($_, $c->stash->{jobs}) foreach
        getPrimaryBuildsForReleaseSet($c->stash->{project}, $c->stash->{primaryJob}, $page, $resultsPerPage);

    $c->stash->{baseUri} = $c->uri_for($self->action_for("view"), $c->stash->{project}->name, $c->stash->{view}->name);
    $c->stash->{results} = [@results];
    $c->stash->{page} = $page;
    $c->stash->{totalResults} = getPrimaryBuildTotal($c->stash->{project}, $c->stash->{primaryJob});
    $c->stash->{resultsPerPage} = $resultsPerPage;
}


sub edit : Chained('view') PathPart('edit') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    $c->stash->{template} = 'edit-view.tt';
}

    
sub latest : Chained('view') PathPart('latest') {
    my ($self, $c, @args) = @_;
    
    # Redirect to the latest result in the view in which every build
    # is successful.
    my $latest = getLatestSuccessfulRelease(
        $c->stash->{project}, $c->stash->{primaryJob}, $c->stash->{jobs});
    error($c, "This view set has no successful results yet.") if !defined $latest;
    return $c->res->redirect($c->uri_for("/view", $c->stash->{project}->name, $c->stash->{view}->name, $latest->id, @args));
}


sub result : Chained('view') PathPart('') {
    my ($self, $c, $id, @args) = @_;
    
    $c->stash->{template} = 'release.tt';

    # Note: we don't actually check whether $id is a primary build,
    # but who cares?
    my $primaryBuild = $c->stash->{project}->builds->find($id,
        { join => 'resultInfo',
        , '+select' => ["resultInfo.releasename", "resultInfo.buildstatus"]
        , '+as' => ["releasename", "buildstatus"] })
        or error($c, "Build $id doesn't exist.");

    $c->stash->{release} = getRelease($primaryBuild, $c->stash->{jobs});

    # Provide a redirect to the specified job of this release.  !!!
    # This isn't uniquely defined if there are multiple jobs with the
    # same name (e.g. builds for different platforms).  However, this
    # mechanism is primarily to allow linking to resources of which
    # there is only one build, such as the manual of the latest
    # release.
    if (scalar @args != 0) {
        my $jobName = shift @args;
        (my $build, my @others) = grep { $_->{job}->job eq $jobName } @{$c->stash->{release}->{jobs}};
        notFound($c, "Release doesn't have a job named `$jobName'")
            unless defined $build;
        error($c, "Job `$jobName' isn't unique.") if @others;
        return $c->res->redirect($c->uri_for($c->controller('Build')->action_for('view_build'),
            [$build->{build}->id], @args));
    }
}


1;
