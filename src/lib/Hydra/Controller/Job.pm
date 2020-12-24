package Hydra::Controller::Job;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Net::Prometheus;

sub job : Chained('/') PathPart('job') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $jobName) = @_;

    $c->stash->{jobset} = $c->model('DB::Jobsets')->find({ project => $projectName, name => $jobsetName });

    if (!$c->stash->{jobset}) {
        my $rename = $c->model('DB::JobsetRenames')->find({ project => $projectName, from_ => $jobsetName });
        notFound($c, "Jobset ‘$jobsetName’ doesn't exist.") unless defined $rename;

        # Return a permanent redirect to the new jobset name.
        my @captures = @{$c->req->captures};
        $captures[1] = $rename->to_;
        $c->res->redirect($c->uri_for($c->action, \@captures, $c->req->params), 301);
        $c->detach;
    }

    $c->stash->{job} = $jobName;
    $c->stash->{project} = $c->stash->{jobset}->project;
}

sub shield :Chained('job') PathPart('shield') Args(0) {
    my ($self, $c) = @_;

    my $job = $c->stash->{job};

    my $lastBuild = $c->stash->{jobset}->builds->find(
        { job => $job, finished => 1 },
        { order_by => 'id DESC', rows => 1, columns => [@buildListColumns] }
    );
    notFound($c, "No latest build for job ‘$job’.") unless defined $lastBuild;

    my $color =
            $lastBuild->buildstatus == 0 ? "green" :
            $lastBuild->buildstatus == 4 ? "yellow" :
            "red";
    my $message =
            $lastBuild->buildstatus == 0 ? "passing" :
            $lastBuild->buildstatus == 4 ? "cancelled" :
            "failing";

    $c->response->content_type('application/json');
    $c->stash->{'plain'} = {
        data => scalar (JSON::Any->objToJson(
            {
                schemaVersion => 1,
                label => "hydra build",
                color => $color,
                message => $message,
            }))
    };
    $c->forward('Hydra::View::Plain');
}


sub prometheus : Chained('job') PathPart('prometheus') Args(0) {
    my ($self, $c) = @_;
    my $prometheus = Net::Prometheus->new;

    my $lastBuild = $c->stash->{jobset}->builds->find(
        { job => $c->stash->{job}, finished => 1 },
        { order_by => 'id DESC', rows => 1, columns => [@buildListColumns] }
    );

    $prometheus->new_counter(
        name => "hydra_job_completion_time",
        help => "The most recent job's completion time",
        labels => [ "project", "jobset", "job" ]
    )->labels(
        $c->stash->{project}->name,
        $c->stash->{jobset}->name,
        $c->stash->{job},
    )->inc($lastBuild->stoptime);

    $prometheus->new_gauge(
        name => "hydra_job_failed",
        help => "Record if the most recent version of this job failed (1 means failed)",
        labels => [ "project", "jobset", "job" ]
    )->labels(
        $c->stash->{project}->name,
        $c->stash->{jobset}->name,
        $c->stash->{job},
    )->inc($lastBuild->buildstatus > 0);

    $c->stash->{'plain'} = { data => $prometheus->render };
    $c->forward('Hydra::View::Plain');
}

sub overview : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'job.tt';

    $c->stash->{lastBuilds} =
        [ $c->stash->{jobset}->builds->search({ job => $c->stash->{job}, finished => 1 },
            { order_by => 'id DESC', rows => 10, columns => [@buildListColumns] }) ];

    $c->stash->{queuedBuilds} = [
        $c->stash->{jobset}->builds->search(
            { job => $c->stash->{job}, finished => 0 },
            { order_by => ["priority DESC", "id"] }
        ) ];

    # If this is an aggregate job, then get its constituents.
    my @constituents = $c->model('DB::Builds')->search(
        { aggregate => { -in => $c->stash->{jobset}->builds->search({ job => $c->stash->{job} }, { columns => ["id"], order_by => "id desc", rows => 15 })->as_query } },
        { join => 'aggregateconstituents_constituents',
          columns => ['id', 'job', 'finished', 'buildstatus'],
          +select => ['aggregateconstituents_constituents.aggregate'],
          +as => ['aggregate']
        });

    my $aggregates = {};
    my %constituentJobs;
    foreach my $b (@constituents) {
        $aggregates->{$b->get_column('aggregate')}->{constituents}->{$b->job} =
            { id => $b->id, finished => $b->finished, buildstatus => $b->buildstatus };
        $constituentJobs{$b->job} = 1;
    }

    foreach my $agg (keys %$aggregates) {
        # FIXME: could be done in one query.
        $aggregates->{$agg}->{build} =
            $c->model('DB::Builds')->find({id => $agg}, {columns => [@buildListColumns]}) or die;
    }

    $c->stash->{aggregates} = $aggregates;
    $c->stash->{constituentJobs} = [sort (keys %constituentJobs)];

    $c->stash->{starred} = $c->user->starredjobs(
        { project => $c->stash->{project}->name
        , jobset => $c->stash->{jobset}->name
        , job => $c->stash->{job}
        })->count == 1 if $c->user_exists;
}


sub metrics_tab : Chained('job') PathPart('metrics-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'job-metrics-tab.tt';
    $c->stash->{metrics} = [ $c->stash->{jobset}->buildmetrics->search(
        { job => $c->stash->{job} }, { select => ["name"], distinct => 1, order_by => "name",  }) ];
}


sub build_times : Chained('job') PathPart('build-times') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{jobset}->builds->search(
        { job => $c->stash->{job}, finished => 1, buildstatus => 0, closuresize => { '!=', 0 } },
        { join => "actualBuildStep"
        , "+select" => ["actualBuildStep.stoptime - actualBuildStep.starttime"]
        , "+as" => ["actualBuildTime"],
        , order_by => "id" });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->get_column('actualBuildTime') } } @res ]);
}


sub closure_sizes : Chained('job') PathPart('closure-sizes') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{jobset}->builds->search(
        { job => $c->stash->{job}, finished => 1, buildstatus => 0, closuresize => { '!=', 0 } },
        { order_by => "id", columns => [ "id", "timestamp", "closuresize" ] });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->closuresize } } @res ]);
}


sub output_sizes : Chained('job') PathPart('output-sizes') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{jobset}->builds->search(
        { job => $c->stash->{job}, finished => 1, buildstatus => 0, size => { '!=', 0 } },
        { order_by => "id", columns => [ "id", "timestamp", "size" ] });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->size } } @res ]);
}


sub metric : Chained('job') PathPart('metric') Args(1) {
    my ($self, $c, $metricName) = @_;

    $c->stash->{template} = 'metric.tt';
    $c->stash->{metricName} = $metricName;

    my @res = $c->stash->{jobset}->buildmetrics->search(
        { job => $c->stash->{job}, name => $metricName },
        { order_by => "timestamp", columns => [ "build", "name", "timestamp", "value", "unit" ] });

    $self->status_ok($c, entity => [ map { { id => $_->get_column("build"), timestamp => $_ ->timestamp, value => $_->value, unit => $_->unit } } @res ]);
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds->search({ job => $c->stash->{job} });
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$c->stash->{jobset}->id, $c->stash->{job}]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job};
}


sub star : Chained('job') PathPart('star') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);
    requireUser($c);
    my $args =
        { project => $c->stash->{project}->name
        , jobset => $c->stash->{jobset}->name
        , job => $c->stash->{job}
        };
    if ($c->request->params->{star} eq "1") {
        $c->user->starredjobs->update_or_create($args);
    } else {
        $c->user->starredjobs->find($args)->delete;
    }
    $c->stash->{resource}->{success} = 1;
}


1;
