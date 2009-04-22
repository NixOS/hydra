package Hydra::Controller::Jobset;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub jobset : Chained('/') PathPart('jobset') CaptureArgs(2) {
    my ($self, $c, $projectName, $jobsetName) = @_;

    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{project} = $project;
    
    $c->stash->{jobset_} = $project->jobsets->search({name => $jobsetName});
    $c->stash->{jobset} = $c->stash->{jobset_}->single
        or notFound($c, "Jobset $jobsetName doesn't exist.");
}


sub index : Chained('jobset') PathPart('') Args(0) {
    my ($self, $c) = @_;
    
    $c->stash->{template} = 'jobset.tt';
    
    getBuildStats($c, scalar $c->stash->{jobset}->builds);

    $c->stash->{activeJobs} = [$c->stash->{jobset}->jobs->search({active => 1})];
    $c->stash->{inactiveJobs} = [$c->stash->{jobset}->jobs->search({active => 0})];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('jobset') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds;
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForJobset')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]});
    $c->stash->{allJobsets} = $c->stash->{jobset_};
    $c->stash->{allJobs} = $c->stash->{jobset}->jobs;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJobset')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name;
}


sub edit : Chained('jobset') PathPart Args(0) {
    my ($self, $c) = @_;
    
    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'jobset.tt';
    $c->stash->{edit} = 1;
}


sub submit : Chained('jobset') PathPart Args(0) {
    my ($self, $c) = @_;
    
    requireProjectOwner($c, $c->stash->{project});
    requirePost($c);
    
    txn_do($c->model('DB')->schema, sub {
        updateJobset($c, $c->stash->{jobset});
    });

    $c->res->redirect($c->uri_for($self->action_for("index"),
        [$c->stash->{project}->name, $c->stash->{jobset}->name]));
}


sub delete : Chained('jobset') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    requirePost($c);
    
    txn_do($c->model('DB')->schema, sub {
        $c->stash->{jobset}->delete;
    });
    
    $c->res->redirect($c->uri_for($c->controller('Project')->action_for("view"),
        [$c->stash->{project}->name]));
}


sub updateJobset {
    my ($c, $jobset) = @_;

    my $jobsetName = trim $c->request->params->{"name"};
    error($c, "Invalid jobset name: $jobsetName") unless $jobsetName =~ /^[[:alpha:]][\w\-]*$/;

    # The Nix expression path must be relative and can't contain ".." elements.
    my $nixExprPath = trim $c->request->params->{"nixexprpath"};
    error($c, "Invalid Nix expression path: $nixExprPath") if $nixExprPath !~ /^$relPathRE$/;

    my $nixExprInput = trim $c->request->params->{"nixexprinput"};
    error($c, "Invalid Nix expression input name: $nixExprInput") unless $nixExprInput =~ /^\w+$/;

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->request->params->{"description"})
        , nixexprpath => $nixExprPath
        , nixexprinput => $nixExprInput
        });

    my %inputNames;
        
    # Process the inputs of this jobset.
    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^input-(\w+)-name$/;
        my $baseName2 = $1;
        next if $baseName2 eq "template";
        print STDERR "GOT INPUT: $baseName2\n";

        my $inputName = trim $c->request->params->{"input-$baseName2-name"};
        error($c, "Invalid input name: $inputName") unless $inputName =~ /^[[:alpha:]]\w*$/;

        my $inputType = trim $c->request->params->{"input-$baseName2-type"};
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
        } else { # it's an existing input
            $input = ($jobset->jobsetinputs->search({name => $baseName2}))[0];
            die unless defined $input;
            $input->update({name => $inputName, type => $inputType});
        }

        # Update the values for this input.  Just delete all the
        # current ones, then create the new values.
        $input->jobsetinputalts->delete_all;
        my $values = $c->request->params->{"input-$baseName2-values"};
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


1;
