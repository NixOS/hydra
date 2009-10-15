package Hydra::Controller::Project;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub project : Chained('/') PathPart('project') CaptureArgs(1) {
    my ($self, $c, $projectName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{project} = $project;
}


sub view : Chained('project') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'project.tt';

    getBuildStats($c, scalar $c->stash->{project}->builds);

    $c->stash->{views} = [$c->stash->{project}->views->all];
}


sub edit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'project.tt';
    $c->stash->{edit} = 1;
}


sub submit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    requirePost($c);
    
    txn_do($c->model('DB')->schema, sub {
        updateProject($c, $c->stash->{project});
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), [$c->stash->{project}->name]));
}


sub delete : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    requirePost($c);
    
    txn_do($c->model('DB')->schema, sub {
        $c->stash->{project}->delete;
    });
    
    $c->res->redirect($c->uri_for("/"));
}


sub requireMayCreateProjects {
    my ($c) = @_;
 
    requireLogin($c) if !$c->user_exists;

    error($c, "Only administrators or authorised users can perform this operation.")
        unless $c->check_user_roles('admin') || $c->check_user_roles('create-projects');
}


sub create : Path('/create-project') {
    my ($self, $c) = @_;

    requireMayCreateProjects($c);

    $c->stash->{template} = 'project.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_submit : Path('/create-project/submit') {
    my ($self, $c) = @_;

    requireMayCreateProjects($c);

    my $projectName = trim $c->request->params->{name};
    
    txn_do($c->model('DB')->schema, sub {
        # Note: $projectName is validated in updateProject,
        # which will abort the transaction if the name isn't
        # valid.  Idem for the owner.
        my $owner = $c->check_user_roles('admin')
            ? trim $c->request->params->{owner} : $c->user->username;
        my $project = $c->model('DB::Projects')->create(
            {name => $projectName, displayname => "", owner => $owner});
        updateProject($c, $project);
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), [$projectName]));
}


sub create_jobset : Chained('project') PathPart('create-jobset') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    $c->stash->{template} = 'jobset.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_jobset_submit : Chained('project') PathPart('create-jobset/submit') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    my $jobsetName = trim $c->request->params->{name};

    txn_do($c->model('DB')->schema, sub {
        # Note: $jobsetName is validated in updateProject, which will
        # abort the transaction if the name isn't valid.
        my $jobset = $c->stash->{project}->jobsets->create(
            {name => $jobsetName, nixexprinput => "", nixexprpath => ""});
        Hydra::Controller::Jobset::updateJobset($c, $jobset);
    });
    
    $c->res->redirect($c->uri_for($c->controller('Jobset')->action_for("index"),
        [$c->stash->{project}->name, $jobsetName]));
}


sub updateProject {
    my ($c, $project) = @_;
    my $projectName = trim $c->request->params->{name};
    error($c, "Invalid project name: " . ($projectName || "(empty)")) unless $projectName =~ /^[[:alpha:]][\w\-]*$/;
    
    my $displayName = trim $c->request->params->{displayname};
    error($c, "Invalid display name: $displayName") if $displayName eq "";

    my $owner = $project->owner;
    if ($c->check_user_roles('admin')) {
        $owner = trim $c->request->params->{owner};
        error($c, "Invalid owner: $owner")
            unless defined $c->model('DB::Users')->find({username => $owner});
    }

    $project->update(
        { name => $projectName
        , displayname => $displayName
        , description => trim($c->request->params->{description})
        , homepage => trim($c->request->params->{homepage})
        , enabled => trim($c->request->params->{enabled}) eq "1" ? 1 : 0
        , owner => $owner
        });
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('project') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{project}->builds;
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForProject')
        ->search({}, {bind => [$c->stash->{project}->name]});
    $c->stash->{allJobsets} = $c->stash->{project}->jobsets;
    $c->stash->{allJobs} = $c->stash->{project}->jobs;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForProject')
        ->search({}, {bind => [$c->stash->{project}->name]});
    $c->stash->{channelBaseName} = $c->stash->{project}->name;
}


1;
