package Hydra::Controller::Jobset;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub jobsetChain :Chained('/') :PathPart('jobset') :CaptureArgs(2) {
    my ($self, $c, $projectName, $jobsetName) = @_;

    my $project = $c->model('DB::Projects')->find($projectName);

    notFound($c, "Project ‘$projectName’ doesn't exist.") if !$project;

    $c->stash->{project} = $project;

    $c->stash->{jobset} = $project->jobsets->find({ name => $jobsetName });

    if (!$c->stash->{jobset} && !($c->action->name eq "jobset" and $c->request->method eq "PUT")) {
        my $rename = $project->jobsetrenames->find({ from_ => $jobsetName });
        notFound($c, "Jobset ‘$jobsetName’ doesn't exist.") unless defined $rename;

        # Return a permanent redirect to the new jobset name.
        my @captures = @{$c->req->captures};
        $captures[1] = $rename->to_;
        $c->res->redirect($c->uri_for($c->action, \@captures, $c->req->params), 301);
        $c->detach;
    }

    $c->stash->{params}->{name} //= $jobsetName;
}


sub jobset :Chained('jobsetChain') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub jobset_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset.tt';

    $c->stash->{evals} = getEvals($self, $c, scalar $c->stash->{jobset}->jobsetevals, 0, 10);

    $c->stash->{latestEval} = $c->stash->{jobset}->jobsetevals->search({}, { rows => 1, order_by => ["id desc"] })->single;

    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);

    $self->status_ok($c, entity => $c->stash->{jobset});
}

sub jobset_PUT {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    if (defined $c->stash->{jobset}) {
        txn_do($c->model('DB')->schema, sub {
            updateJobset($c, $c->stash->{jobset});
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $c->stash->{jobset}->name]) . "#tabs-configuration";
        $self->status_ok($c, entity => { redirect => "$uri" });

        $c->flash->{successMsg} = "The jobset configuration has been updated.";
    }

    else {
        my $jobset;
        txn_do($c->model('DB')->schema, sub {
            # Note: $jobsetName is validated in updateProject, which will
            # abort the transaction if the name isn't valid.
            $jobset = $c->stash->{project}->jobsets->create(
                {name => ".tmp", nixexprinput => "", nixexprpath => "",
                 emailoverride => "", channelattr => ""});
            updateJobset($c, $jobset);
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $jobset->name]);
        $self->status_created($c,
            location => "$uri",
            entity => { name => $jobset->name, uri => "$uri", redirect => "$uri", type => "jobset" });
    }
}

sub jobset_DELETE {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    txn_do($c->model('DB')->schema, sub {
        $c->stash->{jobset}->jobsetevals->delete;
        $c->stash->{jobset}->builds->delete;
        $c->stash->{jobset}->delete;
    });

    my $uri = $c->uri_for($c->controller('Project')->action_for("project"), [$c->stash->{project}->name]);
    $self->status_ok($c, entity => { redirect => "$uri" });

    $c->flash->{successMsg} = "The jobset has been deleted.";
}


sub jobs_tab : Chained('jobsetChain') PathPart('jobs-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-jobs-tab.tt';

    $c->stash->{filter} = $c->request->params->{filter} // "";
    my $filter = "%" . $c->stash->{filter} . "%";

    my @evals = $c->stash->{jobset}->jobsetevals->search({ hasnewbuilds => 1}, { order_by => "id desc", rows => 20 });

    my $evals = {};
    my %jobs;
    my $nrBuilds = 0;

    foreach my $eval (@evals) {
        my @builds = $eval->builds->search(
            { job => { ilike => $filter } },
            { columns => ['id', 'job', 'finished', 'buildstatus'] });
        foreach my $b (@builds) {
            my $jobName = $b->get_column('job');
            $evals->{$eval->id}->{timestamp} = $eval->timestamp;
            $evals->{$eval->id}->{jobs}->{$jobName} =
                { id => $b->id, finished => $b->finished, buildstatus => $b->buildstatus };
            $jobs{$jobName} = 1;
            $nrBuilds++;
        }
        last if $nrBuilds >= 10000;
    }

    if ($c->request->params->{showInactive}) {
        $c->stash->{showInactive} = 1;
        foreach my $job ($c->stash->{jobset}->jobs->search({ name => { ilike => $filter } })) {
            next if defined $jobs{$job->name};
            $c->stash->{inactiveJobs}->{$job->name} = $jobs{$job->name} = 1;
        }
    }

    $c->stash->{evals} = $evals;
    my @jobs = sort (keys %jobs);
    $c->stash->{nrJobs} = scalar @jobs;
    splice @jobs, 250 if $c->stash->{filter} eq "";
    $c->stash->{jobs} = [@jobs];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('jobsetChain') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJobset')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name;
}


sub edit : Chained('jobsetChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{edit} = 1;
    $c->stash->{clone} = defined $c->stash->{params}->{clone};
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
}


sub nixExprPathFromParams {
    my ($c) = @_;

    # The Nix expression path must be relative and can't contain ".." elements.
    my $nixExprPath = trim $c->stash->{params}->{"nixexprpath"};
    error($c, "Invalid Nix expression path ‘$nixExprPath’.") if $nixExprPath !~ /^$relPathRE$/;

    my $nixExprInput = trim $c->stash->{params}->{"nixexprinput"};
    error($c, "Invalid Nix expression input name ‘$nixExprInput’.") unless $nixExprInput =~ /^[[:alpha:]][\w-]*$/;

    return ($nixExprPath, $nixExprInput);
}


sub checkInputValue {
    my ($c, $name, $type, $value) = @_;
    $value = trim $value unless $type eq "string";

    error($c, "The value ‘$value’ of input ‘$name’ is not a Boolean (‘true’ or ‘false’).") if
        $type eq "boolean" && !($value eq "true" || $value eq "false");

    error($c, "The value ‘$value’ of input ‘$name’ does not specify a Hydra evaluation.  "
          . "It should be either the number of a specific evaluation, the name of "
          . "a jobset (given as <project>:<jobset>), or the name of a job (<project>:<jobset>:<job>).")
        if $type eq "eval" && $value !~ /^\d+$/
            && $value !~ /^$projectNameRE:$jobsetNameRE$/
            && $value !~ /^$projectNameRE:$jobsetNameRE:$jobNameRE$/;

    return $value;
}


sub updateJobset {
    my ($c, $jobset) = @_;

    my $oldName = $jobset->name;
    my $jobsetName = $c->stash->{params}->{name};
    error($c, "Invalid jobset identifier ‘$jobsetName’.") if $jobsetName !~ /^$jobsetNameRE$/;

    error($c, "Cannot rename jobset to ‘$jobsetName’ since that identifier is already taken.")
        if $jobsetName ne $oldName && defined $c->stash->{project}->jobsets->find({ name => $jobsetName });

    # When the expression is in a .scm file, assume it's a Guile + Guix
    # build expression.
    my $exprType =
        $c->stash->{params}->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

    my ($nixExprPath, $nixExprInput) = nixExprPathFromParams $c;

    my $enabled = int($c->stash->{params}->{enabled});
    die if $enabled < 0 || $enabled > 2;

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->stash->{params}->{"description"})
        , nixexprpath => $nixExprPath
        , nixexprinput => $nixExprInput
        , channelattr => $c->stash->{params}->{"channelattr"}
        , enabled => $enabled
        , enableemail => defined $c->stash->{params}->{enableemail} ? 1 : 0
        , emailoverride => trim($c->stash->{params}->{emailoverride}) || ""
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , keepnr => int(trim($c->stash->{params}->{keepnr}))
        , checkinterval => int(trim($c->stash->{params}->{checkinterval}))
        , triggertime => $enabled ? $jobset->triggertime // time() : undef
        , schedulingshares => int($c->stash->{params}->{schedulingshares})
        });

    $jobset->project->jobsetrenames->search({ from_ => $jobsetName })->delete;
    $jobset->project->jobsetrenames->create({ from_ => $oldName, to_ => $jobsetName })
        if $oldName ne ".tmp" && $jobsetName ne $oldName;

    # Set the inputs of this jobset.
    $jobset->jobsetinputs->delete;

    foreach my $name (keys %{$c->stash->{params}->{inputs}}) {
        my $inputData = $c->stash->{params}->{inputs}->{$name};
        my $type = $inputData->{type};
        my $value = $inputData->{value};
        my $emailresponsible = defined $inputData->{emailresponsible} ? 1 : 0;

        error($c, "Invalid input name ‘$name’.") unless $name =~ /^[[:alpha:]][\w-]*$/;
        error($c, "Invalid input type ‘$type’.") unless defined $c->stash->{inputTypes}->{$type};

        my $input = $jobset->jobsetinputs->create(
            { name => $name,
              type => $type,
              emailresponsible => $emailresponsible
            });

        $value = checkInputValue($c, $name, $type, $value);
        $input->jobsetinputalts->create({altnr => 0, value => $value});
    }
}


sub clone : Chained('jobsetChain') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{clone} = 1;
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
}


sub evals :Chained('jobsetChain') :PathPart('evals') :Args(0) :ActionClass('REST') { }

sub evals_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->stash->{jobset}->jobsetevals;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({hasnewbuilds => 1})->count;
    my $offset = ($page - 1) * $resultsPerPage;
    $c->stash->{evals} = getEvals($self, $c, $evals, $offset, $resultsPerPage);
    my %entity = (
        evals => [ map { $_->{eval} } @{$c->stash->{evals}} ],
        first => "?page=1",
        last => "?page=" . POSIX::ceil($c->stash->{total}/$resultsPerPage)
    );
    if ($page > 1) {
        $entity{previous} = "?page=" . ($page - 1);
    }
    if ($page < POSIX::ceil($c->stash->{total}/$resultsPerPage)) {
        $entity{next} = "?page=" . ($page + 1);
    }
    $self->status_ok(
        $c,
        entity => \%entity
    );
}


# Redirect to the latest finished evaluation of this jobset.
sub latest_eval : Chained('jobsetChain') PathPart('latest-eval') {
    my ($self, $c, @args) = @_;
    my $eval = getLatestFinishedEval($c->stash->{jobset})
        or notFound($c, "No evaluation found.");
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @args, $c->req->params));
}


1;
