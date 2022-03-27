package Hydra::Controller::Project;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub projectChain :Chained('/') :PathPart('project') :CaptureArgs(1) {
    my ($self, $c, $projectName) = @_;
    $c->stash->{params}->{name} //= $projectName;

    my $isCreate = $c->action->name eq "project" && $c->request->method eq "PUT";

    $c->stash->{project} = $c->model('DB::Projects')->find($projectName);

    $c->stash->{isProjectOwner} = !$isCreate && isProjectOwner($c, $c->stash->{project});

    notFound($c, "Project ‘$projectName’ doesn't exist.")
        if !$c->stash->{project} && !$isCreate;
}


sub project :Chained('projectChain') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub project_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'project.tt';

    $c->stash->{jobsets} = [jobsetOverview($c, $c->stash->{project})];

    $self->status_ok($c, entity => $c->stash->{project});
}

sub project_PUT {
    my ($self, $c) = @_;

    if (defined $c->stash->{project}) {
        requireProjectOwner($c, $c->stash->{project});

        $c->model('DB')->schema->txn_do(sub {
            updateProject($c, $c->stash->{project});
        });

        my $uri = $c->uri_for($self->action_for("project"), [$c->stash->{project}->name]) . "#tabs-configuration";
        $self->status_ok($c, entity => { redirect => "$uri" });

        $c->flash->{successMsg} = "The project configuration has been updated.";
    }

    else {
        requireMayCreateProjects($c);

        my $project;
        $c->model('DB')->schema->txn_do(sub {
            # Note: $projectName is validated in updateProject,
            # which will abort the transaction if the name isn't
            # valid.  Idem for the owner.
            my $owner = $c->user->username;
            $project = $c->model('DB::Projects')->create(
                { name => ".tmp", displayname => "", owner => $owner });
            updateProject($c, $project);
        });

        my $uri = $c->uri_for($self->action_for("project"), [$project->name]);
        $self->status_created($c,
            location => "$uri",
            entity => { name => $project->name, uri => "$uri", redirect => "$uri", type => "project" });
    }
}

sub project_DELETE {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->model('DB')->schema->txn_do(sub {
        $c->stash->{project}->builds->search_related('buildsbymaintainers')->delete;
        $c->stash->{project}->builds->delete;
        $c->stash->{project}->jobsets->delete;
        $c->stash->{project}->delete;
    });

    my $uri = $c->res->redirect($c->uri_for("/"));
    $self->status_ok($c, entity => { redirect => "$uri" });

    $c->flash->{successMsg} = "The project has been deleted.";
}


sub edit : Chained('projectChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-project.tt';
    $c->stash->{edit} = 1;
}


sub requireMayCreateProjects {
    my ($c) = @_;
    requireUser($c);
    accessDenied($c, "Only administrators or authorised users can perform this operation.")
        unless $c->check_user_roles('admin') || $c->check_user_roles('create-projects');
}


sub create : Path('/create-project') {
    my ($self, $c) = @_;

    requireMayCreateProjects($c);

    $c->stash->{template} = 'edit-project.tt';
    $c->stash->{create} = 1;
}


sub create_jobset : Chained('projectChain') PathPart('create-jobset') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{create} = 1;
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
    $c->stash->{emailNotification} = $c->config->{email_notification} // 0;
}


sub updateProject {
    my ($c, $project) = @_;

    my $owner = $project->owner;
    if ($c->check_user_roles('admin') and defined $c->stash->{params}->{owner}) {
        $owner = trim $c->stash->{params}->{owner};
        badRequest($c, "The user name ‘$owner’ does not exist.")
            unless defined $c->model('DB::Users')->find($owner);
    }

    my $projectName = $c->stash->{params}->{name};
    error($c, "Invalid project identifier ‘$projectName’.") if $projectName !~ /^$projectNameRE$/;

    error($c, "Cannot rename project to ‘$projectName’ since that identifier is already taken.")
        if $projectName ne $project->name && defined $c->model('DB::Projects')->find($projectName);

    my $displayName = trim $c->stash->{params}->{displayname};
    error($c, "You must specify a display name.") if $displayName eq "";

    $project->update(
        { name => $projectName
        , displayname => $displayName
        , description => trim($c->stash->{params}->{description})
        , homepage => trim($c->stash->{params}->{homepage})
        , enabled => defined $c->stash->{params}->{enabled} ? 1 : 0
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , owner => $owner
        , declfile => trim($c->stash->{params}->{declarative}->{file})
        , decltype => trim($c->stash->{params}->{declarative}->{type})
        , declvalue => trim($c->stash->{params}->{declarative}->{value})
        });
    if (length($project->declfile)) {
        # This logic also exists in the DeclarativeJobets tests.
        # TODO: refactor and deduplicate.
        $project->jobsets->update_or_create(
            { name=> ".jobsets"
            , nixexprinput => ""
            , nixexprpath => ""
            , emailoverride => ""
            , triggertime => time
            });
    } else {
        $project->jobsets->search({ name => ".jobsets" })->delete;
        $project->update(
            { decltype => ""
            , declvalue => ""
            });
    }
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('projectChain') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{project}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForProject')
        ->search({}, {bind => [$c->stash->{project}->name]});
    $c->stash->{channelBaseName} = $c->stash->{project}->name;
}


1;
