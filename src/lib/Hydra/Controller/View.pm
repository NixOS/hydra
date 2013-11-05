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


sub updateView {
    my ($c, $view) = @_;

    my $viewName = trim $c->request->params->{name};
    error($c, "Invalid view name: $viewName")
        unless $viewName =~ /^[[:alpha:]][\w\-]*$/;

    $view->update(
        { name => $viewName
        , description => trim $c->request->params->{description} });

    $view->viewjobs->delete;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^job-(\d+)-name$/;
        my $baseName = $1;

        my $name = trim $c->request->params->{"job-$baseName-name"};
        my $description = trim $c->request->params->{"job-$baseName-description"};
        my $attrs = trim $c->request->params->{"job-$baseName-attrs"};

        $name =~ /^([\w\-]+):($jobNameRE)$/ or error($c, "Invalid job name: $name");
        my $jobsetName = $1;
        my $jobName = $2;

        error($c, "Jobset `$jobsetName' doesn't exist.")
            unless $view->project->jobsets->find({name => $jobsetName});

        # !!! We could check whether the job exists, but that would
        # require the evaluator to have seen the job, which may not be
        # the case.

        $view->viewjobs->create(
            { jobset => $jobsetName
            , job => $jobName
            , description => $description
            , attrs => $attrs
            , isprimary => $c->request->params->{"primary"} eq $baseName ? 1 : 0
            });
    }

    error($c, "There must be one primary job.")
        if $view->viewjobs->search({isprimary => 1})->count != 1;
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
    my $page = int($c->req->param('page') || "1") || 1;

    my @results = ();
    push @results, getViewResult($_, $c->stash->{jobs}) foreach
        getPrimaryBuildsForView($c->stash->{project}, $c->stash->{primaryJob}, $page, $resultsPerPage);

    $c->stash->{baseUri} = $c->uri_for($self->action_for("view_view"), $c->req->captures);
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


sub submit : Chained('view') PathPart('submit') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    if (($c->request->params->{submit} || "") eq "delete") {
        $c->stash->{view}->delete;
        $c->res->redirect($c->uri_for($c->controller('Project')->action_for('project'),
            [$c->stash->{project}->name]));
    }
    txn_do($c->model('DB')->schema, sub {
        updateView($c, $c->stash->{view});
    });
    $c->res->redirect($c->uri_for($self->action_for("view_view"), $c->req->captures));
}


sub latest : Chained('view') PathPart('latest') {
    my ($self, $c, @args) = @_;

    # Redirect to the latest result in the view in which every build
    # is successful.
    my $latest = getLatestSuccessfulViewResult(
        $c->stash->{project}, $c->stash->{primaryJob}, $c->stash->{jobs}, 0);
    error($c, "This view set has no successful results yet.") if !defined $latest;
    $c->res->redirect($c->uri_for($self->action_for("view_view"), $c->req->captures, $latest->id, @args, $c->req->params));
}


sub latest_finished : Chained('view') PathPart('latest-finished') {
    my ($self, $c, @args) = @_;

    # Redirect to the latest result in the view in which every build
    # is successful *and* where the jobset evaluation has finished
    # completely.
    my $latest = getLatestSuccessfulViewResult(
        $c->stash->{project}, $c->stash->{primaryJob}, $c->stash->{jobs}, 1);
    error($c, "This view set has no successful results yet.") if !defined $latest;
    $c->res->redirect($c->uri_for($self->action_for("view_view"), $c->req->captures, $latest->id, @args, $c->req->params));
}


sub result : Chained('view') PathPart('') {
    my ($self, $c, $id, @args) = @_;

    $c->stash->{template} = 'view-result.tt';

    # Note: we don't actually check whether $id is a primary build,
    # but who cares?
    my $primaryBuild = $c->stash->{project}->builds->find($id)
        or error($c, "Build $id doesn't exist.");

    my $result = getViewResult($primaryBuild, $c->stash->{jobs});
    $c->stash->{result} = $result;

    my %jobNames;
    $jobNames{$_->{job}->job}++ foreach @{$result->{jobs}};
    $c->stash->{jobNames} = \%jobNames;

    if (scalar @args == 1 && $args[0] eq "release") {
        requireProjectOwner($c, $c->stash->{project});

        error($c, "The primary build of this view result did not provide a release name.")
            unless $result->{releasename};

        error($c, "A release named `" . $result->{releasename} . "' already exists.")
            if $c->stash->{project}->releases->find({name => $result->{releasename}});

        my $release;

        txn_do($c->model('DB')->schema, sub {

            $release = $c->stash->{project}->releases->create(
                { name => $result->{releasename}
                , timestamp => time
                });

            foreach my $job (@{$result->{jobs}}) {
                $release->releasemembers->create(
                    { build => $job->{build}->id
                    , description => $job->{job}->description
                    });
            }
        });

        $c->res->redirect($c->uri_for($c->controller('Release')->action_for('view'),
            [$c->stash->{project}->name, $release->name]));
    }

    elsif (scalar @args >= 1 && $args[0] eq "eval") {
        my $eval = $c->stash->{result}->{eval};
        notFound($c, "This view result has no evaluation.") unless defined $eval;
        $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"),
            [$eval->id], @args[1..$#args], $c->req->params));
    }

    # Provide a redirect to the specified job of this view result
    # through `http://.../view/$project/$viewName/$viewResult/$jobName'.
    # Optionally, you can append `-$system' to the $jobName to get a
    # build for a specific platform.
    elsif (scalar @args != 0) {
        my $jobName = shift @args;
        my $system;
        if ($jobName =~ /^($jobNameRE)-($systemRE)$/) {
            $jobName = $1;
            $system = $2;
        }
        (my $build, my @others) =
            grep { $_->{job}->job eq $jobName && (!defined $system || ($_->{build} && $_->{build}->system eq $system)) }
            @{$result->{jobs}};
        notFound($c, "View doesn't have a job named ‘$jobName’" . ($system ? " for ‘$system’" : "") . ".")
            unless defined $build;
        error($c, "Job `$jobName' isn't unique.") if @others;
        return $c->res->redirect($c->uri_for($c->controller('Build')->action_for('build'),
            [$build->{build}->id], @args));
    }
}


1;
