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

    my $projectName = $c->stash->{project}->name;
    my $jobsetName = $c->stash->{jobset}->name;

    $c->stash->{evals} = getEvals($self, $c, scalar $c->stash->{jobset}->jobsetevals, 0, 10);

    ($c->stash->{latestEval}) = $c->stash->{jobset}->jobsetevals->search({}, { limit => 1, order_by => ["id desc"] });
}


sub jobs_tab : Chained('jobset') PathPart('jobs-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-jobs-tab.tt';

    $c->stash->{activeJobs} = [];
    $c->stash->{inactiveJobs} = [];

    (my $latestEval) = $c->stash->{jobset}->jobsetevals->search(
        { hasnewbuilds => 1}, { limit => 1, order_by => ["id desc"] });

    my %activeJobs;
    if (defined $latestEval) {
        foreach my $build ($latestEval->builds->search({}, { order_by => ["job"], select => ["job"] })) {
            my $job = $build->get_column("job");
            if (!defined $activeJobs{$job}) {
                $activeJobs{$job} = 1;
                push @{$c->stash->{activeJobs}}, $job;
            }
        }
    }

    foreach my $job ($c->stash->{jobset}->jobs->search({}, { order_by => ["name"] })) {
        if (!defined $activeJobs{$job->name}) {
            push @{$c->stash->{inactiveJobs}}, $job->name;
        }
    }
}


sub status_tab : Chained('jobset') PathPart('status-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-status-tab.tt';

    # FIXME: use latest eval instead of iscurrent.

    $c->stash->{systems} =
        [ $c->stash->{jobset}->builds->search({ iscurrent => 1 }, { select => ["system"], distinct => 1, order_by => "system" }) ];

    # status per system
    my @systems = ();
    foreach my $system (@{$c->stash->{systems}}) {
        push(@systems, $system->system);
    }

    my @select = ();
    my @as = ();
    push(@select, "job"); push(@as, "job");
    foreach my $system (@systems) {
        push(@select, "(select buildstatus from Builds b where b.id = (select max(id) from Builds t where t.project = me.project and t.jobset = me.jobset and t.job = me.job and t.system = '$system' and t.iscurrent = 1 ))");
        push(@as, $system);
        push(@select, "(select b.id from Builds b where b.id = (select max(id) from Builds t where t.project = me.project and t.jobset = me.jobset and t.job = me.job and t.system = '$system' and t.iscurrent = 1 ))");
        push(@as, "$system-build");
    }

    $c->stash->{activeJobsStatus} = [
        $c->model('DB')->resultset('ActiveJobsForJobset')->search(
            {},
            { bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]
            , select => \@select
            , as => \@as
            , order_by => ["job"]
            }) ];
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

    $c->stash->{template} = 'edit-jobset.tt';
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


sub nixExprPathFromParams {
    my ($c) = @_;

    # The Nix expression path must be relative and can't contain ".." elements.
    my $nixExprPath = trim $c->request->params->{"nixexprpath"};
    error($c, "Invalid Nix expression path: $nixExprPath") if $nixExprPath !~ /^$relPathRE$/;

    my $nixExprInput = trim $c->request->params->{"nixexprinput"};
    error($c, "Invalid Nix expression input name: $nixExprInput") unless $nixExprInput =~ /^\w+$/;

    return ($nixExprPath, $nixExprInput);
}


sub checkInput {
    my ($c, $baseName) = @_;

    my $inputName = trim $c->request->params->{"input-$baseName-name"};
    error($c, "Invalid input name: $inputName") unless $inputName =~ /^[[:alpha:]]\w*$/;

    my $inputType = trim $c->request->params->{"input-$baseName-type"};
    error($c, "Invalid input type: $inputType") unless
        $inputType eq "svn" || $inputType eq "svn-checkout" || $inputType eq "hg" || $inputType eq "tarball" ||
        $inputType eq "string" || $inputType eq "path" || $inputType eq "boolean" || $inputType eq "bzr" || $inputType eq "bzr-checkout" ||
        $inputType eq "git" || $inputType eq "build" || $inputType eq "sysbuild" ;

    return ($inputName, $inputType);
}


sub checkInputValue {
    my ($c, $type, $value) = @_;
    $value = trim $value;
    error($c, "Invalid Boolean value: $value") if
        $type eq "boolean" && !($value eq "true" || $value eq "false");
    return $value;
}


sub updateJobset {
    my ($c, $jobset) = @_;

    my $jobsetName = trim $c->request->params->{"name"};
    error($c, "Invalid jobset name: ‘$jobsetName’") if $jobsetName !~ /^$jobsetNameRE$/;

    # When the expression is in a .scm file, assume it's a Guile + Guix
    # build expression.
    my $exprType =
        $c->request->params->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

    my ($nixExprPath, $nixExprInput) = nixExprPathFromParams $c;

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->request->params->{"description"})
        , nixexprpath => $nixExprPath
        , nixexprinput => $nixExprInput
        , enabled => defined $c->request->params->{enabled} ? 1 : 0
        , enableemail => defined $c->request->params->{enableemail} ? 1 : 0
        , emailoverride => trim($c->request->params->{emailoverride}) || ""
        , hidden => defined $c->request->params->{visible} ? 0 : 1
        , keepnr => trim($c->request->params->{keepnr}) || 3
        });

    my %inputNames;

    # Process the inputs of this jobset.
    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^input-(\w+)-name$/;
        my $baseName = $1;
        next if $baseName eq "template";

        my ($inputName, $inputType) = checkInput($c, $baseName);

        $inputNames{$inputName} = 1;

        my $input;
        if ($baseName =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
            $input = $jobset->jobsetinputs->create(
                { name => $inputName
                , type => $inputType
                });
        } else { # it's an existing input
            $input = ($jobset->jobsetinputs->search({name => $baseName}))[0];
            die unless defined $input;
            $input->update({name => $inputName, type => $inputType});
        }

        # Update the values for this input.  Just delete all the
        # current ones, then create the new values.
        $input->jobsetinputalts->delete_all;
        my $values = $c->request->params->{"input-$baseName-values"};
        $values = [] unless defined $values;
        $values = [$values] unless ref($values) eq 'ARRAY';
        my $altnr = 0;
        foreach my $value (@{$values}) {
            $value = checkInputValue($c, $inputType, $value);
            $input->jobsetinputalts->create({altnr => $altnr++, value => $value});
        }
    }

    # Get rid of deleted inputs.
    my @inputs = $jobset->jobsetinputs->all;
    foreach my $input (@inputs) {
        $input->delete unless defined $inputNames{$input->name};
    }
}


sub clone : Chained('jobset') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    my $jobset = $c->stash->{jobset};
    requireProjectOwner($c, $jobset->project);

    $c->stash->{template} = 'clone-jobset.tt';
}


sub clone_submit : Chained('jobset') PathPart('clone/submit') Args(0) {
    my ($self, $c) = @_;

    my $jobset = $c->stash->{jobset};
    requireProjectOwner($c, $jobset->project);
    requirePost($c);

    my $newJobsetName = trim $c->request->params->{"newjobset"};
    error($c, "Invalid jobset name: $newJobsetName") unless $newJobsetName =~ /^[[:alpha:]][\w\-]*$/;

    my $newJobset;
    txn_do($c->model('DB')->schema, sub {
        $newJobset = $jobset->project->jobsets->create(
            { name => $newJobsetName
            , description => $jobset->description
            , nixexprpath => $jobset->nixexprpath
            , nixexprinput => $jobset->nixexprinput
            , enabled => 0
            , enableemail => $jobset->enableemail
            , emailoverride => $jobset->emailoverride || ""
            });

        foreach my $input ($jobset->jobsetinputs) {
            my $newinput = $newJobset->jobsetinputs->create({name => $input->name, type => $input->type});
            foreach my $inputalt ($input->jobsetinputalts) {
                $newinput->jobsetinputalts->create({altnr => $inputalt->altnr, value => $inputalt->value});
            }
        }
    });

    $c->res->redirect($c->uri_for($c->controller('Jobset')->action_for("edit"), [$jobset->project->name, $newJobsetName]));
}


sub evals : Chained('jobset') PathPart('evals') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->stash->{jobset}->jobsetevals;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({hasnewbuilds => 1})->count;
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage)
}


# Redirect to the latest finished evaluation of this jobset.
sub latest_eval : Chained('jobset') PathPart('latest-eval') {
    my ($self, $c, @args) = @_;
    my $eval = getLatestFinishedEval($c, $c->stash->{jobset})
        or notFound($c, "No evaluation found.");
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @args, $c->req->params));
}


1;
