package Hydra::Controller::Project;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub projectChain :Chained('/') :PathPart('project') :CaptureArgs(1) {
    my ($self, $c, $projectName) = @_;

    my $project = $c->model('DB::Projects')->find($projectName, { columns => [
      "me.name",
      "me.displayName",
      "me.description",
      "me.enabled",
      "me.hidden",
      "me.homepage",
      "owner.username",
      "owner.fullname",
      "views.name",
      "releases.name",
      "releases.timestamp",
      "jobsets.name",
      "jobsets.disabled",
    ], join => [ 'owner', 'views', 'releases', 'jobsets' ], order_by => { -desc => "releases.timestamp" }, collapse => 1 });

    if ($project) {
        $c->stash->{project} = $project;
    } else {
        if ($c->action->name eq "project" and $c->request->method eq "PUT") {
            $c->stash->{projectName} = $projectName;
        } else {
            $self->status_not_found(
                $c,
                message => "Project $projectName doesn't exist."
            );
            $c->detach;
        }
    }
}


sub project :Chained('projectChain') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub project_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'project.tt';

    $c->stash->{views} = [$c->stash->{project}->views->all];
    $c->stash->{jobsets} = [jobsetOverview($c, $c->stash->{project})];
    $c->stash->{releases} = [$c->stash->{project}->releases->search({},
        {order_by => ["timestamp DESC"]})];

    $self->status_ok(
        $c,
        entity => $c->stash->{project}
    );
}

sub project_PUT {
    my ($self, $c) = @_;

    if (defined $c->stash->{project}) {
        error($c, "Cannot rename project `$c->stash->{params}->{oldName}' over existing project `$c->stash->{project}->name") if defined $c->stash->{params}->{oldName};
        requireProjectOwner($c, $c->stash->{project});
        txn_do($c->model('DB')->schema, sub {
            updateProject($c, $c->stash->{project});
        });

        if ($c->req->looks_like_browser) {
            $c->res->redirect($c->uri_for($self->action_for("project"), [$c->stash->{project}->name]) . "#tabs-configuration");
        } else {
            $self->status_no_content($c);
        }
    } elsif (defined $c->stash->{params}->{oldName}) {
        my $project = $c->model('DB::Projects')->find($c->stash->{params}->{oldName});
        if (defined $project) {
            requireProjectOwner($c, $project);
            txn_do($c->model('DB')->schema, sub {
                updateProject($c, $project);
            });

            my $uri = $c->uri_for($self->action_for("project"), [$project->name]);

            if ($c->req->looks_like_browser) {
                $c->res->redirect($uri . "#tabs-configuration");
            } else {
                $self->status_created(
                    $c,
                    location => "$uri",
                    entity => { name => $project->name, uri => "$uri", type => "project" }
                );
            }
        } else {
            $self->status_not_found(
                $c,
                message => "Project $c->stash->{params}->{oldName} doesn't exist."
            );
        }
    } else {
        requireMayCreateProjects($c);
        error($c, "Invalid project name: ‘$c->stash->{projectName}’") if $c->stash->{projectName} !~ /^$projectNameRE$/;

        my $project;
        txn_do($c->model('DB')->schema, sub {
            # Note: $projectName is validated in updateProject,
            # which will abort the transaction if the name isn't
            # valid.  Idem for the owner.
            my $owner = $c->user->username;
            $project = $c->model('DB::Projects')->create(
                {name => $c->stash->{projectName}, displayname => "", owner => $owner});
            updateProject($c, $project);
        });

        my $uri = $c->uri_for($self->action_for("project"), [$project->name]);
        if ($c->req->looks_like_browser) {
            $c->res->redirect($uri . "#tabs-configuration");
        } else {
            $self->status_created(
                $c,
                location => "$uri",
                entity => { name => $project->name, uri => "$uri", type => "project" }
            );
        }
    }
}


sub edit : Chained('projectChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-project.tt';
    $c->stash->{edit} = 1;
}


sub submit : Chained('projectChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requirePost($c);
    if (($c->request->params->{submit} // "") eq "delete") {
        txn_do($c->model('DB')->schema, sub {
            $c->stash->{project}->jobsetevals->delete_all;
            $c->stash->{project}->builds->delete_all;
            $c->stash->{project}->delete;
        });
        return $c->res->redirect($c->uri_for("/"));
    }

    my $newName = trim $c->stash->{params}->{name};
    my $oldName = trim $c->stash->{project}->name;
    unless ($oldName eq $newName) {
        $c->stash->{params}->{oldName} = $oldName;
        $c->stash->{projectName} = $newName;
        undef $c->stash->{project};
    }
    project_PUT($self, $c);
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

    $c->stash->{template} = 'edit-project.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_submit : Path('/create-project/submit') {
    my ($self, $c) = @_;

    $c->stash->{projectName} = trim $c->stash->{params}->{name};

    project_PUT($self, $c);
}


sub create_jobset : Chained('projectChain') PathPart('create-jobset') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_jobset_submit : Chained('projectChain') PathPart('create-jobset/submit') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{jobsetName} = trim $c->stash->{params}->{name};

    Hydra::Controller::Jobset::jobset_PUT($self, $c);
}


sub updateProject {
    my ($c, $project) = @_;

    my $owner = $project->owner;
    if ($c->check_user_roles('admin') and defined $c->stash->{params}->{owner}) {
        $owner = trim $c->stash->{params}->{owner};
        error($c, "Invalid owner: $owner")
            unless defined $c->model('DB::Users')->find({username => $owner});
    }

    my $projectName = $c->stash->{projectName} or $project->name;
    error($c, "Invalid project name: ‘$projectName’") if $projectName !~ /^$projectNameRE$/;

    my $displayName = trim $c->stash->{params}->{displayname};
    error($c, "Invalid display name: $displayName") if $displayName eq "";

    $project->update(
        { name => $projectName
        , displayname => $displayName
        , description => trim($c->stash->{params}->{description})
        , homepage => trim($c->stash->{params}->{homepage})
        , enabled => defined $c->stash->{params}->{enabled} ? 1 : 0
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , owner => $owner
        });
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('projectChain') PathPart('') CaptureArgs(0) {
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


sub create_view_submit : Chained('projectChain') PathPart('create-view/submit') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    my $viewName = $c->request->params->{name};

    my $view;
    txn_do($c->model('DB')->schema, sub {
        # Note: $viewName is validated in updateView, which will abort
        # the transaction if the name isn't valid.
        $view = $c->stash->{project}->views->create({name => $viewName});
        Hydra::Controller::View::updateView($c, $view);
    });

    $c->res->redirect($c->uri_for($c->controller('View')->action_for('view_view'),
        [$c->stash->{project}->name, $view->name]));
}


sub create_view : Chained('projectChain') PathPart('create-view') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-view.tt';
    $c->stash->{create} = 1;
}


sub create_release : Chained('projectChain') PathPart('create-release') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    $c->stash->{template} = 'edit-release.tt';
    $c->stash->{create} = 1;
}


sub create_release_submit : Chained('projectChain') PathPart('create-release/submit') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    my $releaseName = $c->request->params->{name};

    my $release;
    txn_do($c->model('DB')->schema, sub {
        # Note: $releaseName is validated in updateRelease, which will
        # abort the transaction if the name isn't valid.
        $release = $c->stash->{project}->releases->create(
            { name => $releaseName
            , timestamp => time
            });
        Hydra::Controller::Release::updateRelease($c, $release);
    });

    $c->res->redirect($c->uri_for($c->controller('Release')->action_for('view'),
        [$c->stash->{project}->name, $release->name]));
}


1;
