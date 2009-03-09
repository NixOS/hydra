package Hydra::Controller::Project;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub project : Chained('/') PathPart('project') CaptureArgs(1) {
    my ($self, $c, $projectName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") unless defined $project;

    $c->stash->{curProject} = $project;
}


sub view : Chained('project') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'project.tt';

    getBuildStats($c, scalar $c->stash->{curProject}->builds);
}


sub edit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{curProject});

    $c->stash->{template} = 'project.tt';
    $c->stash->{edit} = 1;
}


sub submit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{curProject});

    error($c, "Request must be POSTed.") if $c->request->method ne "POST";
    
    $c->model('DB')->schema->txn_do(sub {
        updateProject($c, $c->stash->{curProject});
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), $c->req->captures));
}


sub delete : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{curProject});

    error($c, "Request must be POSTed.") if $c->request->method ne "POST";
    
    $c->model('DB')->schema->txn_do(sub {
        $c->stash->{curProject}->delete;
    });
    
    $c->res->redirect($c->uri_for("/"));
}


sub create : Path('/create-project') {
    my ($self, $c) = @_;

    requireAdmin($c);

    $c->stash->{template} = 'project.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_submit : Path('/create-project/submit') {
    my ($self, $c) = @_;

    requireAdmin($c);

    my $projectName = trim $c->request->params->{name};
    
    $c->model('DB')->schema->txn_do(sub {
        # Note: $projectName is validated in updateProject,
        # which will abort the transaction if the name isn't
        # valid.  Idem for the owner.
        my $project = $c->model('DB::Projects')->create(
            {name => $projectName, displayname => "", owner => trim $c->request->params->{owner}});
        updateProject($c, $project);
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), [$projectName]));
}


sub updateProject {
    my ($c, $project) = @_;
    my $projectName = trim $c->request->params->{name};
    error($c, "Invalid project name: " . ($projectName || "(empty)")) unless $projectName =~ /^[[:alpha:]]\w*$/;
    
    my $displayName = trim $c->request->params->{displayname};
    error($c, "Invalid display name: $displayName") if $displayName eq "";
    
    $project->name($projectName);
    $project->displayname($displayName);
    $project->description(trim $c->request->params->{description});
    $project->homepage(trim $c->request->params->{homepage});
    $project->enabled(trim($c->request->params->{enabled}) eq "1" ? 1 : 0);

    if ($c->check_user_roles('admin')) {
        my $owner = trim $c->request->params->{owner};
        error($c, "Invalid owner: $owner")
            unless defined $c->model('DB::Users')->find({username => $owner});
        $project->owner($owner);
    }

    $project->update;
    
    my %jobsetNames;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^jobset-(\w+)-name$/;
        my $baseName = $1;
        next if $baseName eq "template";

        my $jobsetName = trim $c->request->params->{"jobset-$baseName-name"};
        error($c, "Invalid jobset name: $jobsetName") unless $jobsetName =~ /^[[:alpha:]]\w*$/;

        # The Nix expression path must be relative and can't contain ".." elements.
        my $nixExprPath = trim $c->request->params->{"jobset-$baseName-nixexprpath"};
        error($c, "Invalid Nix expression path: $nixExprPath") if $nixExprPath !~ /^$relPathRE$/;

        my $nixExprInput = trim $c->request->params->{"jobset-$baseName-nixexprinput"};
        error($c, "Invalid Nix expression input name: $nixExprInput") unless $nixExprInput =~ /^\w+$/;

        $jobsetNames{$jobsetName} = 1;

        my $jobset;

        my $description = trim $c->request->params->{"jobset-$baseName-description"};

        if ($baseName =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
            $jobset = $project->jobsets->create(
                { name => $jobsetName
                , description => $description
                , nixexprpath => $nixExprPath
                , nixexprinput => $nixExprInput
                });
        } else { # it's an existing jobset
            $jobset = ($project->jobsets->search({name => $baseName}))[0];
            die unless defined $jobset;
            $jobset->update(
                { name => $jobsetName, description => $description
                , nixexprpath => $nixExprPath, nixexprinput => $nixExprInput });
        }

        my %inputNames;
        
        # Process the inputs of this jobset.
        foreach my $param (keys %{$c->request->params}) {
            next unless $param =~ /^jobset-$baseName-input-(\w+)-name$/;
            my $baseName2 = $1;
            next if $baseName2 eq "template";
            print STDERR "GOT INPUT: $baseName2\n";

            my $inputName = trim $c->request->params->{"jobset-$baseName-input-$baseName2-name"};
            error($c, "Invalid input name: $inputName") unless $inputName =~ /^[[:alpha:]]\w*$/;

            my $inputType = trim $c->request->params->{"jobset-$baseName-input-$baseName2-type"};
            error($c, "Invalid input type: $inputType") unless
                $inputType eq "svn" || $inputType eq "cvs" || $inputType eq "tarball" ||
                $inputType eq "string" || $inputType eq "path" || $inputType eq "boolean" ||
                $inputType eq "build";

            $inputNames{$inputName} = 1;
            
            my $input;
            if ($baseName2 =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
                $input = $jobset->jobsetinputs->create(
                    { name => $inputName
                    , type => $inputType
                    });
            } else { # it's an existing jobset
                $input = ($jobset->jobsetinputs->search({name => $baseName2}))[0];
                die unless defined $input;
                $input->update({name => $inputName, type => $inputType});
            }

            # Update the values for this input.  Just delete all the
            # current ones, then create the new values.
            $input->jobsetinputalts->delete_all;
            my $values = $c->request->params->{"jobset-$baseName-input-$baseName2-values"};
            $values = [] unless defined $values;
            $values = [$values] unless ref($values) eq 'ARRAY';
            my $altnr = 0;
            foreach my $value (@{$values}) {
                print STDERR "VALUE: $value\n";
                my $value = trim $value;
                error($c, "Invalid Boolean value: $value") if
                    $inputType eq "boolean" && !($value eq "true" || $value eq "false");
                $input->jobsetinputalts->create({altnr => $altnr++, value => $value});
            }
        }

        # Get rid of deleted inputs.
        my @inputs = $jobset->jobsetinputs->all;
        foreach my $input (@inputs) {
            $input->delete unless defined $inputNames{$input->name};
        }
    }

    # Get rid of deleted jobsets, i.e., ones that are no longer submitted in the parameters.
    my @jobsets = $project->jobsets->all;
    foreach my $jobset (@jobsets) {
        $jobset->delete unless defined $jobsetNames{$jobset->name};
    }
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('project') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{curProject}->builds;
    $c->stash->{channelBaseName} = $c->stash->{curProject}->name;
}


1;
