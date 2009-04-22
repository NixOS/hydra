package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub begin :Private {
    my ($self, $c) = @_;
    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
}


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search({}, {order_by => 'displayname'})];
    getBuildStats($c, $c->model('DB::Builds'));
}


sub login :Local {
    my ($self, $c) = @_;
    
    my $username = $c->request->params->{username} || "";
    my $password = $c->request->params->{password} || "";

    if ($username && $password) {
        if ($c->authenticate({username => $username, password => $password})) {
            $c->response->redirect(
                defined $c->flash->{afterLogin}
                ? $c->flash->{afterLogin}
                : $c->uri_for('/'));
            return;
        }
        $c->stash->{errorMsg} = "Bad username or password.";
    }
    
    $c->stash->{template} = 'login.tt';
}


sub logout :Local {
    my ($self, $c) = @_;
    $c->logout;
    $c->response->redirect($c->uri_for('/'));
}


sub queue :Local {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{queue} = [$c->model('DB::Builds')->search(
        {finished => 0}, {join => 'schedulingInfo', order_by => ["priority DESC", "timestamp"]})];
}


sub getReleaseSet {
    my ($c, $projectName, $releaseSetName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{project} = $project;

    (my $releaseSet) = $c->model('DB::ReleaseSets')->find($projectName, $releaseSetName);
    notFound($c, "Release set $releaseSetName doesn't exist.") if !defined $releaseSet;
    $c->stash->{releaseSet} = $releaseSet;

    (my $primaryJob) = $releaseSet->releasesetjobs->search({isprimary => 1});
    #die "Release set $releaseSetName doesn't have a primary job." if !defined $primaryJob;

    my $jobs = [$releaseSet->releasesetjobs->search({},
        {order_by => ["isprimary DESC", "job", "attrs"]})];

    $c->stash->{jobs} = $jobs;

    return ($project, $releaseSet, $primaryJob, $jobs);
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


sub releases :Local {
    my ($self, $c, $projectName, $releaseSetName, $subcommand) = @_;

    my ($project, $releaseSet, $primaryJob, $jobs) = getReleaseSet($c, $projectName, $releaseSetName);

    if (defined $subcommand && $subcommand ne "") {

        requireProjectOwner($c, $project);

        if ($subcommand eq "edit") {
            $c->stash->{template} = 'edit-releaseset.tt';
            return;
        }

        elsif ($subcommand eq "submit") {
            txn_do($c->model('DB')->schema, sub {
                updateReleaseSet($c, $releaseSet);
            });
            return $c->res->redirect($c->uri_for("/releases", $projectName, $releaseSet->name));
        }

        elsif ($subcommand eq "delete") {
            txn_do($c->model('DB')->schema, sub {
                $releaseSet->delete;
            });
            return $c->res->redirect($c->uri_for($c->controller('Project')->action_for('view'), [$project->name]));
        }

        else { error($c, "Unknown subcommand."); }
    }
    
    $c->stash->{template} = 'releases.tt';

    my @releases = ();
    push @releases, getRelease($_, $jobs) foreach getPrimaryBuildsForReleaseSet($project, $primaryJob);
    $c->stash->{releases} = [@releases];
}


sub create_releaseset :Local {
    my ($self, $c, $projectName, $subcommand) = @_;

    my $project = $c->model('DB::Projects')->find($projectName);
    error($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{project} = $project;

    requireProjectOwner($c, $project);

    if (defined $subcommand && $subcommand eq "submit") {
        my $releaseSetName = $c->request->params->{name};
        txn_do($c->model('DB')->schema, sub {
            # Note: $releaseSetName is validated in updateProject,
            # which will abort the transaction if the name isn't
            # valid.
            my $releaseSet = $project->releasesets->create({name => $releaseSetName});
            updateReleaseSet($c, $releaseSet);
            return $c->res->redirect($c->uri_for("/releases", $projectName, $releaseSet->name));
        });
    }
    
    $c->stash->{template} = 'edit-releaseset.tt';
    $c->stash->{create} = 1;
}


sub release :Local {
    my ($self, $c, $projectName, $releaseSetName, $releaseId, @args) = @_;
    $c->stash->{template} = 'release.tt';

    my ($project, $releaseSet, $primaryJob, $jobs) = getReleaseSet($c, $projectName, $releaseSetName);

    if ($releaseId eq "latest") {
        # Redirect to the latest successful release.
        my $latest = getLatestSuccessfulRelease($project, $primaryJob, $jobs);
        error($c, "This release set has no successful releases yet.") if !defined $latest;
        return $c->res->redirect($c->uri_for("/release", $projectName, $releaseSetName, $latest->id, @args));
    }

    # Note: we don't actually check whether $releaseId is a primary
    # build, but who cares?
    my $primaryBuild = $project->builds->find($releaseId,
        { join => 'resultInfo',
        , '+select' => ["resultInfo.releasename", "resultInfo.buildstatus"]
        , '+as' => ["releasename", "buildstatus"] })
        or error($c, "Release $releaseId doesn't exist.");

    $c->stash->{release} = getRelease($primaryBuild, $jobs);

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


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatus');
    $c->stash->{allJobsets} = $c->model('DB::Jobsets');
    $c->stash->{allJobs} = $c->model('DB::Jobs');
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceeded');
    $c->stash->{channelBaseName} = "everything";
}


sub robots_txt : Path('robots.txt') {
    my ($self, $c) = @_;

    sub uri_for {
        my ($controller, $action, @args) = @_;
        return $c->uri_for($c->controller($controller)->action_for($action), @args)->path;
    }

    sub channelUris {
        my ($controller, $bindings) = @_;
        return
            ( uri_for($controller, 'closure', $bindings, "*")
            , uri_for($controller, 'manifest', $bindings)
            , uri_for($controller, 'nar', $bindings, "*")
            , uri_for($controller, 'pkg', $bindings, "*")
            , uri_for($controller, 'nixexprs', $bindings)
            );
    }

    # Put actions that are expensive or not useful for indexing in
    # robots.txt.  Note: wildcards are not universally supported in
    # robots.txt, but apparently Google supports them.
    my @rules =
        ( uri_for('Build', 'buildtimedeps', ["*"])
        , uri_for('Build', 'runtimedeps', ["*"])
        , uri_for('Build', 'view_nixlog', ["*"], "*")
        , channelUris('Root', ["*"])
        , channelUris('Project', ["*", "*"])
        , channelUris('Jobset', ["*", "*", "*"])
        , channelUris('Job', ["*", "*", "*", "*"])
        , channelUris('Build', ["*"])
        );
    
    $c->stash->{'plain'} = { data => "User-agent: *\n" . join('', map { "Disallow: $_\n" } @rules) };
    $c->forward('Hydra::View::Plain');
}

    
sub default :Path {
    my ($self, $c) = @_;
    notFound($c, "Page not found.");
}


sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    if (scalar @{$c->error}) {
        $c->stash->{template} = 'error.tt';
        $c->stash->{errors} = $c->error;
        if ($c->response->status >= 300) {
            $c->stash->{httpStatus} =
                $c->response->status . " " . HTTP::Status::status_message($c->response->status);
        }
        $c->clear_errors;
    }
}


1;
