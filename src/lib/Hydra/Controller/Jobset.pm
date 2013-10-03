package Hydra::Controller::Jobset;

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

    $c->stash->{jobset_} = $project->jobsets->search({'me.name' => $jobsetName});
    my $jobset = $c->stash->{jobset_}->single;

    if ($jobset) {
        $c->stash->{jobset} = $jobset;
    } else {
        if ($c->action->name eq "jobset" and $c->request->method eq "PUT") {
            $c->stash->{jobsetName} = $jobsetName;
        } else {
            notFound($c, "Jobset ‘$jobsetName’ doesn't exist.");
        }
    }
}


sub jobset :Chained('jobsetChain') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub jobset_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset.tt';

    $c->stash->{evals} = getEvals($self, $c, scalar $c->stash->{jobset}->jobsetevals, 0, 10);

    $c->stash->{latestEval} = $c->stash->{jobset}->jobsetevals->search({}, { rows => 1, order_by => ["id desc"] })->single;

    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);

    $self->status_ok(
        $c,
        entity => $c->stash->{jobset_}->find({}, {
                columns => [
                    'me.name',
                    'me.project',
                    'me.errormsg',
                    'me.emailoverride',
                    'jobsetinputs.name',
                    {
                        'jobsetinputs.jobsetinputalts.altnr' => 'jobsetinputalts.altnr',
                        'jobsetinputs.jobsetinputalts.value' => 'jobsetinputalts.value'
                    }
                ],
                join => { 'jobsetinputs' => 'jobsetinputalts' },
                collapse => 1,
                order_by => "me.name"
            })
    );
}

sub jobset_PUT {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    if (defined $c->stash->{jobset}) {
        error($c, "Cannot rename jobset `$c->stash->{params}->{oldName}' over existing jobset `$c->stash->{jobset}->name") if defined $c->stash->{params}->{oldName} and $c->stash->{params}->{oldName} ne $c->stash->{jobset}->name;
        txn_do($c->model('DB')->schema, sub {
            updateJobset($c, $c->stash->{jobset});
        });

        if ($c->req->looks_like_browser) {
            $c->res->redirect($c->uri_for($self->action_for("jobset"),
                [$c->stash->{project}->name, $c->stash->{jobset}->name]) . "#tabs-configuration");
        } else {
            $self->status_no_content($c);
        }
    } elsif (defined $c->stash->{params}->{oldName}) {
        my $jobset = $c->stash->{project}->jobsets->find({'me.name' => $c->stash->{params}->{oldName}});

        if (defined $jobset) {
            txn_do($c->model('DB')->schema, sub {
                updateJobset($c, $jobset);
            });

            my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $jobset->name]);

            if ($c->req->looks_like_browser) {
                $c->res->redirect($uri . "#tabs-configuration");
            } else {
                $self->status_created(
                    $c,
                    location => "$uri",
                    entity => { name => $jobset->name, uri => "$uri", type => "jobset" }
                );
            }
        } else {
            $self->status_not_found(
                $c,
                message => "Jobset $c->stash->{params}->{oldName} doesn't exist."
            );
        }
    } else {
        my $exprType =
            $c->stash->{params}->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

        error($c, "Invalid jobset name: ‘$c->stash->{jobsetName}’") if $c->stash->{jobsetName} !~ /^$jobsetNameRE$/;

        my $jobset;
        txn_do($c->model('DB')->schema, sub {
            # Note: $jobsetName is validated in updateProject, which will
            # abort the transaction if the name isn't valid.
            $jobset = $c->stash->{project}->jobsets->create(
                {name => $c->stash->{jobsetName}, nixexprinput => "", nixexprpath => "", emailoverride => ""});
            updateJobset($c, $jobset);
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $jobset->name]);
        if ($c->req->looks_like_browser) {
            $c->res->redirect($uri . "#tabs-configuration");
        } else {
            $self->status_created(
                $c,
                location => "$uri",
                entity => { name => $jobset->name, uri => "$uri", type => "jobset" }
            );
        }
    }
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
            $evals->{$eval->id}->{$jobName} = 
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
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForJobset')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]});
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
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
}


sub submit : Chained('jobsetChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requirePost($c);
    requireProjectOwner($c, $c->stash->{project});

    if (($c->request->params->{submit} // "") eq "delete") {
        txn_do($c->model('DB')->schema, sub {
            $c->stash->{jobset}->jobsetevals->delete_all;
            $c->stash->{jobset}->builds->delete_all;
            $c->stash->{jobset}->delete;
        });
        return $c->res->redirect($c->uri_for($c->controller('Project')->action_for("project"), [$c->stash->{project}->name]));
    }

    my $newName = trim $c->stash->{params}->{name};
    my $oldName = trim $c->stash->{jobset}->name;
    unless ($oldName eq $newName) {
        $c->stash->{params}->{oldName} = $oldName;
        $c->stash->{jobsetName} = $newName;
        undef $c->stash->{jobset};
    }
    jobset_PUT($self, $c);
}


sub nixExprPathFromParams {
    my ($c) = @_;

    # The Nix expression path must be relative and can't contain ".." elements.
    my $nixExprPath = trim $c->stash->{params}->{"nixexprpath"};
    error($c, "Invalid Nix expression path: $nixExprPath") if $nixExprPath !~ /^$relPathRE$/;

    my $nixExprInput = trim $c->stash->{params}->{"nixexprinput"};
    error($c, "Invalid Nix expression input name: $nixExprInput") unless $nixExprInput =~ /^[[:alpha:]][\w-]*$/;

    return ($nixExprPath, $nixExprInput);
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

    my $jobsetName = $c->stash->{jobsetName} // $jobset->name;
    error($c, "Invalid jobset name: ‘$jobsetName’") if $jobsetName !~ /^$jobsetNameRE$/;

    # When the expression is in a .scm file, assume it's a Guile + Guix
    # build expression.
    my $exprType =
        $c->stash->{params}->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

    my ($nixExprPath, $nixExprInput) = nixExprPathFromParams $c;

    my $enabled = defined $c->stash->{params}->{enabled};

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->stash->{params}->{"description"})
        , nixexprpath => $nixExprPath
        , nixexprinput => $nixExprInput
        , enabled => $enabled ? 1 : 0
        , enableemail => defined $c->stash->{params}->{enableemail} ? 1 : 0
        , emailoverride => trim($c->stash->{params}->{emailoverride}) || ""
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , keepnr => int(trim($c->stash->{params}->{keepnr}))
        , checkinterval => int(trim($c->stash->{params}->{checkinterval}))
        , triggertime => $enabled ? $jobset->triggertime // time() : undef
        , schedulingshares => int($c->stash->{params}->{schedulingshares})
        });

    # Process the inputs of this jobset.
    unless (defined $c->stash->{params}->{inputs}) {
        $c->stash->{params}->{inputs} = {};
        foreach my $param (keys %{$c->stash->{params}}) {
            next unless $param =~ /^input-(\w+)-name$/;
            my $baseName = $1;
            next if $baseName eq "template";
            $c->stash->{params}->{inputs}->{$c->stash->{params}->{$param}} = { type => $c->stash->{params}->{"input-$baseName-type"}, values => $c->stash->{params}->{"input-$baseName-values"} };
            unless ($baseName =~ /^\d+$/) { # non-numeric base name is an existing entry
                $c->stash->{params}->{inputs}->{$c->stash->{params}->{$param}}->{oldName} = $baseName;
            }
        }
    }

    foreach my $inputName (keys %{$c->stash->{params}->{inputs}}) {
        my $inputData = $c->stash->{params}->{inputs}->{$inputName};
        error($c, "Invalid input name: $inputName") unless $inputName =~ /^[[:alpha:]][\w-]*$/;

        my $inputType = $inputData->{type};

        error($c, "Invalid input type: $inputType") unless defined $c->stash->{inputTypes}->{$inputType};

        my $input;
        unless (defined $inputData->{oldName}) {
            $input = $jobset->jobsetinputs->update_or_create(
                { name => $inputName
                , type => $inputType
                });
        } else { # it's an existing input
            $input = ($jobset->jobsetinputs->search({name => $inputData->{oldName}}))[0];
            die unless defined $input;
            $input->update({name => $inputName, type => $inputType});
        }

        # Update the values for this input.  Just delete all the
        # current ones, then create the new values.
        $input->jobsetinputalts->delete_all;
        my $values = $inputData->{values};
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
        $input->delete unless defined $c->stash->{params}->{inputs}->{$input->name};
    }
}


sub clone : Chained('jobsetChain') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    my $jobset = $c->stash->{jobset};
    requireProjectOwner($c, $jobset->project);

    $c->stash->{template} = 'clone-jobset.tt';
}


sub clone_submit : Chained('jobsetChain') PathPart('clone/submit') Args(0) {
    my ($self, $c) = @_;

    my $jobset = $c->stash->{jobset};
    requireProjectOwner($c, $jobset->project);
    requirePost($c);

    my $newJobsetName = trim $c->stash->{params}->{"newjobset"};
    error($c, "Invalid jobset name: $newJobsetName") if $newJobsetName !~ /^$jobsetNameRE$/;

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
        evals => [ $evals->search({ 'me.hasnewbuilds' => 1 }, {
                    columns => [
                        'me.hasnewbuilds',
                        'me.id',
                        'jobsetevalinputs.name',
                        'jobsetevalinputs.altnr',
                        'jobsetevalinputs.revision',
                        'jobsetevalinputs.type',
                        'jobsetevalinputs.uri',
                        'jobsetevalinputs.dependency',
                        'jobsetevalmembers.build',
                    ],
                    join => [ 'jobsetevalinputs', 'jobsetevalmembers' ],
                    collapse => 1,
                    rows => $resultsPerPage,
                    offset => $offset,
                    order_by => "me.id DESC",
                 }) ],
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
    my $eval = getLatestFinishedEval($c, $c->stash->{jobset})
        or notFound($c, "No evaluation found.");
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @args, $c->req->params));
}


1;
