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

    $c->stash->{evals} = getEvals($c, scalar $c->stash->{jobset}->jobsetevals, 0, 10);

    $c->stash->{latestEval} = $c->stash->{jobset}->jobsetevals->search({ hasnewbuilds => 1 }, { rows => 1, order_by => ["id desc"] })->single;

    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);

    $c->stash->{emailNotification} = $c->config->{email_notification} // 0;

    $self->status_ok($c, entity => $c->stash->{jobset});
}

sub jobset_PUT {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    if (length($c->stash->{project}->declfile)) {
        error($c, "can't modify jobset of declarative project", 403);
    }

    if (defined $c->stash->{jobset}) {
        $c->model('DB')->schema->txn_do(sub {
            updateJobset($c, $c->stash->{jobset});
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $c->stash->{jobset}->name]) . "#tabs-configuration";
        $self->status_ok($c, entity => { redirect => "$uri" });

        $c->flash->{successMsg} = "The jobset configuration has been updated.";
    }

    else {
        my $jobset;
        $c->model('DB')->schema->txn_do(sub {
            # Note: $jobsetName is validated in updateProject, which will
            # abort the transaction if the name isn't valid.
            $jobset = $c->stash->{project}->jobsets->create(
                {name => ".tmp", nixexprinput => "", nixexprpath => "", emailoverride => ""});
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

    #requireProjectOwner($c, $c->stash->{project});

    requireAdmin($c);

    if (length($c->stash->{project}->declfile)) {
        error($c, "can't modify jobset of declarative project", 403);
    }

    $c->model('DB')->schema->txn_do(sub {
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

    my ($evals, $builds) = searchBuildsAndEvalsForJobset(
        $c->stash->{jobset},
        { job => { ilike => $filter }, ischannel => 0 },
        10000
    );

    if ($c->request->params->{showInactive}) {
        $c->stash->{showInactive} = 1;
        foreach my $job ($c->stash->{jobset}->jobs->search({ name => { ilike => $filter } })) {
            next if defined $builds->{$job->name};
            $c->stash->{inactiveJobs}->{$job->name} = $builds->{$job->name} = 1;
        }
    }

    $c->stash->{evals} = $evals;
    my @jobs = sort (keys %$builds);
    $c->stash->{nrJobs} = scalar @jobs;
    splice @jobs, 250 if $c->stash->{filter} eq "";
    $c->stash->{jobs} = [@jobs];
}


sub channels_tab : Chained('jobsetChain') PathPart('channels-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-channels-tab.tt';

    my ($evals, $builds) = searchBuildsAndEvalsForJobset(
        $c->stash->{jobset},
        { ischannel => 1 }
    );

    $c->stash->{evals} = $evals;
    my @channels = sort (keys %$builds);
    $c->stash->{channels} = [@channels];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('jobsetChain') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJobset')
        ->search({}, {bind => [$c->stash->{jobset}->id]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name;
}


sub edit : Chained('jobsetChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{edit} = !defined $c->stash->{params}->{cloneJobset};
    $c->stash->{cloneJobset} = defined $c->stash->{params}->{cloneJobset};
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
    $c->stash->{emailNotification} = $c->config->{email_notification} // 0;
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


sub knownInputTypes {
    my ($c) = @_;

    my @keys = keys %{$c->stash->{inputTypes}};
    my $types = "";
    my $counter = 0;

    foreach my $key (@keys) {
        $types = $types . "and ‘$key’" if ++$counter == scalar(@keys);
        $types = $types . "‘$key’, " if $counter != scalar(@keys);
    }

    return $types;
}


sub updateJobset {
    my ($c, $jobset) = @_;

    my $oldName = $jobset->name;
    my $jobsetName = $c->stash->{params}->{name};
    error($c, "Invalid jobset identifier ‘$jobsetName’.") if $jobsetName !~ /^$jobsetNameRE$/;

    error($c, "Cannot rename jobset to ‘$jobsetName’ since that identifier is already taken.")
        if $jobsetName ne $oldName && defined $c->stash->{project}->jobsets->find({ name => $jobsetName });

    my $type = int($c->stash->{params}->{"type"} // 0);

    my ($nixExprPath, $nixExprInput);
    my $flake;

    if ($type == 0) {
        ($nixExprPath, $nixExprInput) = nixExprPathFromParams $c;
    } elsif ($type == 1) {
        $flake = trim($c->stash->{params}->{"flake"});
        error($c, "Invalid flake URI ‘$flake’.") if $flake !~ /^[a-zA-Z]/;
    } else {
        error($c, "Invalid jobset type.");
    }

    my $enabled = int($c->stash->{params}->{enabled});
    die if $enabled < 0 || $enabled > 3;

    my $shares = int($c->stash->{params}->{schedulingshares} // 1);
    error($c, "The number of scheduling shares must be positive.") if $shares <= 0;

    my $checkinterval = int(trim($c->stash->{params}->{checkinterval}));

    my $enable_dynamic_run_command = defined $c->stash->{params}->{enable_dynamic_run_command} ? 1 : 0;
    if ($enable_dynamic_run_command
        && !($c->config->{dynamicruncommand}->{enable}
            && $jobset->project->enable_dynamic_run_command))
    {
        badRequest($c, "Dynamic RunCommand is not enabled by the server or the parent project.");
    }

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->stash->{params}->{"description"})
        , nixexprpath => $nixExprPath
        , nixexprinput => $nixExprInput
        , enabled => $enabled
        , enableemail => defined $c->stash->{params}->{enableemail} ? 1 : 0
        , enable_dynamic_run_command => $enable_dynamic_run_command
        , emailoverride => trim($c->stash->{params}->{emailoverride}) || ""
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , keepnr => int(trim($c->stash->{params}->{keepnr} // "0"))
        , checkinterval => $checkinterval
        , triggertime => ($enabled && $checkinterval > 0) ? $jobset->triggertime // time() : undef
        , schedulingshares => $shares
        , type => $type
        , flake => $flake
        });

    $jobset->project->jobsetrenames->search({ from_ => $jobsetName })->delete;
    $jobset->project->jobsetrenames->create({ from_ => $oldName, to_ => $jobsetName })
        if $oldName ne ".tmp" && $jobsetName ne $oldName;

    # Set the inputs of this jobset.
    $jobset->jobsetinputs->delete;

    if ($type == 0) {
        foreach my $name (keys %{$c->stash->{params}->{inputs}}) {
            my $inputData = $c->stash->{params}->{inputs}->{$name};
            my $type = $inputData->{type};
            my $value = $inputData->{value};
            my $emailresponsible = defined $inputData->{emailresponsible} ? 1 : 0;
            my $types = knownInputTypes($c);

            badRequest($c, "Invalid input name ‘$name’.") unless $name =~ /^[[:alpha:]][\w-]*$/;
            badRequest($c, "Invalid input type ‘$type’; valid types: $types.") unless defined $c->stash->{inputTypes}->{$type};

            my $input = $jobset->jobsetinputs->create(
                { name => $name,
                  type => $type,
                  emailresponsible => $emailresponsible
                });

            $value = checkInputValue($c, $name, $type, $value);
            $input->jobsetinputalts->create({altnr => 0, value => $value});
        }
    }
}


sub clone : Chained('jobsetChain') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{cloneJobset} = 1;
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
    $c->stash->{evals} = getEvals($c, $evals, $offset, $resultsPerPage);
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

sub errors :Chained('jobsetChain') :PathPart('errors') :Args(0) :ActionClass('REST') { }

sub errors_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'eval-error.tt';

    $self->status_ok($c, entity => $c->stash->{jobset});
}

# Redirect to the latest finished evaluation of this jobset.
sub latest_eval : Chained('jobsetChain') PathPart('latest-eval') {
    my ($self, $c, @args) = @_;
    my $eval = getLatestFinishedEval($c->stash->{jobset})
        or notFound($c, "No evaluation found.");
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @args, $c->req->params));
}


1;
