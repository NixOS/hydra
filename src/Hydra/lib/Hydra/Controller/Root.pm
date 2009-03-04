package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub begin :Private {
    my ($self, $c) = @_;
    $c->stash->{projects} = [$c->model('DB::Projects')->search({}, {order_by => 'displayname'})];
    $c->stash->{curUri} = $c->request->uri;
}


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'index.tt';
    
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


sub releasesets :Local {
    my ($self, $c, $projectName) = @_;
    $c->stash->{template} = 'releasesets.tt';

    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{curProject} = $project;

    $c->stash->{releaseSets} = [$project->releasesets->all];
}


sub getReleaseSet {
    my ($c, $projectName, $releaseSetName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    die "Project $projectName doesn't exist." if !defined $project;
    $c->stash->{curProject} = $project;

    (my $releaseSet) = $c->model('DB::ReleaseSets')->find($projectName, $releaseSetName);
    die "Release set $releaseSetName doesn't exist." if !defined $releaseSet;
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
    die "Invalid release set name: $releaseSetName" unless $releaseSetName =~ /^[[:alpha:]]\w*$/;
    
    $releaseSet->name($releaseSetName);
    $releaseSet->description(trim $c->request->params->{description});
    $releaseSet->update;

    $releaseSet->releasesetjobs->delete_all;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^job-(\d+)-name$/;
        my $baseName = $1;

        my $name = trim $c->request->params->{"job-$baseName-name"};
        my $description = trim $c->request->params->{"job-$baseName-description"};
        my $attrs = trim $c->request->params->{"job-$baseName-attrs"};

        die "Invalid job name: $name" unless $name =~ /^\w+$/;
        
        $releaseSet->releasesetjobs->create(
            { job => $name
            , description => $description
            , attrs => $attrs
            , isprimary => $c->request->params->{"primary"} eq $baseName ? 1 : 0
            });
    }

    die "There must be one primary job." if $releaseSet->releasesetjobs->search({isprimary => 1})->count != 1;
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
            $c->model('DB')->schema->txn_do(sub {
                updateReleaseSet($c, $releaseSet);
            });
            return $c->res->redirect($c->uri_for("/releases", $projectName, $releaseSet->name));
        }

        elsif ($subcommand eq "delete") {
            $c->model('DB')->schema->txn_do(sub {
                $releaseSet->delete;
            });
            return $c->res->redirect($c->uri_for("/releasesets", $projectName));
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
    die "Project $projectName doesn't exist." if !defined $project;
    $c->stash->{curProject} = $project;

    requireProjectOwner($c, $project);

    if (defined $subcommand && $subcommand eq "submit") {
        my $releaseSetName = $c->request->params->{name};
        $c->model('DB')->schema->txn_do(sub {
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
    my ($self, $c, $projectName, $releaseSetName, $releaseId) = @_;
    $c->stash->{template} = 'release.tt';

    my ($project, $releaseSet, $primaryJob, $jobs) = getReleaseSet($c, $projectName, $releaseSetName);

    if ($releaseId eq "latest") {
        # Redirect to the latest successful release.
        my $latest = getLatestSuccessfulRelease($project, $primaryJob, $jobs);
        error($c, "This release set has no successful releases yet.") if !defined $latest;
        return $c->res->redirect($c->uri_for("/release", $projectName, $releaseSetName, $latest->id));
    }
    
    # Note: we don't actually check whether $releaseId is a primary
    # build, but who cares?
    my $primaryBuild = $project->builds->find($releaseId,
        { join => 'resultInfo', '+select' => ["resultInfo.releasename"], '+as' => ["releasename"] });
    error($c, "Release $releaseId doesn't exist.") if !defined $primaryBuild;
    
    $c->stash->{release} = getRelease($primaryBuild, $jobs);
}


sub job :Local {
    my ($self, $c, $projectName, $jobName) = @_;
    $c->stash->{template} = 'job.tt';

    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{curProject} = $project;

    $c->stash->{jobName} = $jobName;
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        {finished => 1, project => $projectName, attrName => $jobName},
        {order_by => "timestamp DESC"})];
}


sub nix : Chained('/') PathPart('channel/latest') CaptureArgs(0) {
    my ($self, $c) = @_;

    $c->stash->{channelName} = "hydra-all-latest";

    my @builds = @{getLatestBuilds($c, $c->model('DB::Builds'), {buildStatus => 0})};

    my @storePaths = ();
    foreach my $build (@builds) {
        # !!! better do this in getLatestBuilds with a join.
        next unless $build->buildproducts->find({type => "nix-build"});
        next unless isValidPath($build->outpath);
        push @storePaths, $build->outpath;
        my $pkgName = $build->nixname . "-" . $build->system . "-" . $build->id . ".nixpkg";
        $c->stash->{nixPkgs}->{$pkgName} = $build;
    };

    $c->stash->{storePaths} = [@storePaths];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
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
