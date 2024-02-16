package Hydra::Controller::JobsetEval;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::BuildDiff;
use List::SomeUtils qw(uniq);


sub evalChain : Chained('/') PathPart('eval') CaptureArgs(1) {
    my ($self, $c, $evalId) = @_;

    my $eval = $c->model('DB::JobsetEvals')->find($evalId)
        or notFound($c, "Evaluation $evalId doesn't exist.");

    $c->stash->{eval} = $eval;
    $c->stash->{jobset} = $eval->jobset;
    $c->stash->{project} = $eval->jobset->project;
}


sub view :Chained('evalChain') :PathPart('') :Args(0) :ActionClass('REST') { }

sub view_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset-eval.tt';

    my $eval = $c->stash->{eval};

    $c->stash->{filter} = $c->request->params->{filter} // "";
    my $filter = $c->stash->{filter} eq "" ? {} : { job => { ilike => "%" . $c->stash->{filter} . "%" } };

    my $compare = $c->req->params->{compare};
    my $eval2;

    # Allow comparing this evaluation against the previous evaluation
    # (default), an arbitrary evaluation, or the latest completed
    # evaluation of another jobset.
    if (defined $compare) {
        if ($compare =~ /^\d+$/) {
            $eval2 = $c->model('DB::JobsetEvals')->find($compare)
                or notFound($c, "Evaluation $compare doesn't exist.");
        } elsif ($compare =~ /^-(\d+)$/) {
            my $t = int($1);
            $eval2 = $c->stash->{jobset}->jobsetevals->find(
                { hasnewbuilds => 1, timestamp => {'<=', $eval->timestamp - $t} },
                { order_by => "timestamp desc", rows => 1});
        } elsif (defined $compare && $compare =~ /^($jobsetNameRE)$/) {
            my $j = $c->stash->{project}->jobsets->find({name => $compare})
                or notFound($c, "Jobset $compare doesn't exist.");
            $eval2 = getLatestFinishedEval($j);
        } else {
            notFound($c, "Unknown comparison source ‘$compare’.");
        }
    } else {
        ($eval2) = $eval->jobset->jobsetevals->search(
            { hasnewbuilds => 1, id => { '<', $eval->id } },
            { order_by => "id DESC", rows => 1 });
    }

    $c->stash->{otherEval} = $eval2 if defined $eval2;

    my @builds = $eval->builds->search($filter, { columns => [@buildListColumns] });
    my @builds2 = defined $eval2 ? $eval2->builds->search($filter, { columns => [@buildListColumns] }) : ();

    my $diff = buildDiff([@builds], [@builds2]);
    $c->stash->{stillSucceed} = $diff->{stillSucceed};
    $c->stash->{stillFail} = $diff->{stillFail};
    $c->stash->{nowSucceed} = $diff->{nowSucceed};
    $c->stash->{nowFail} = $diff->{nowFail};
    $c->stash->{new} = $diff->{new};
    $c->stash->{removed} = $diff->{removed};
    $c->stash->{unfinished} = $diff->{unfinished};
    $c->stash->{aborted} = $diff->{aborted};
    $c->stash->{failed} = $diff->{failed};

    $c->stash->{full} = ($c->req->params->{full} || "0") eq "1";

    $self->status_ok(
        $c,
        entity => $eval
    );
}

sub errors :Chained('evalChain') :PathPart('errors') :Args(0) :ActionClass('REST') { }

sub errors_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'eval-error.tt';

    $self->status_ok($c, entity => $c->stash->{eval});
}

sub create_jobset : Chained('evalChain') PathPart('create-jobset') Args(0) {
    my ($self, $c) = @_;
    my $eval = $c->stash->{eval};

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{createFromEval} = 1;
}


sub cancel : Chained('evalChain') PathPart('cancel') Args(0) {
    my ($self, $c) = @_;
    requireCancelBuildPrivileges($c, $c->stash->{project});
    my $n = cancelBuilds($c->model('DB')->schema, $c->stash->{eval}->builds->search_rs({}));
    $c->flash->{successMsg} = "$n builds have been cancelled.";
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for('view'), $c->req->captures));
}


sub restart {
    my ($self, $c, $condition) = @_;
    requireRestartPrivileges($c, $c->stash->{project});
    my $builds = $c->stash->{eval}->builds->search_rs({ finished => 1, buildstatus => $condition });
    my $n = restartBuilds($c->model('DB')->schema, $builds);
    $c->flash->{successMsg} = "$n builds have been restarted.";
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for('view'), $c->req->captures));
}


sub restart_aborted : Chained('evalChain') PathPart('restart-aborted') Args(0) {
    my ($self, $c) = @_;
    restart($self, $c, { -in => [3, 4, 9] });
}


sub restart_failed : Chained('evalChain') PathPart('restart-failed') Args(0) {
    my ($self, $c) = @_;
    restart($self, $c, { 'not in' => [0] });
}


sub bump : Chained('evalChain') PathPart('bump') Args(0) {
    my ($self, $c) = @_;
    requireBumpPrivileges($c, $c->stash->{project}); # FIXME: require admin?
    my $builds = $c->stash->{eval}->builds->search({ finished => 0 });
    my $n = $builds->count();
    $c->model('DB')->schema->txn_do(sub {
        $builds->update({globalpriority => time()});
    });
    $c->flash->{successMsg} = "$n builds have been bumped to the front of the queue.";
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for('view'), $c->req->captures));
}


# Hydra::Base::Controller::NixChannel needs this.
sub nix : Chained('evalChain') PathPart('channel') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{channelName} = $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-latest";
    $c->stash->{channelBuilds} = $c->stash->{eval}->builds
        ->search_literal("exists (select 1 from buildproducts where build = build.id and type = 'nix-build')")
        ->search({ finished => 1, buildstatus => 0 },
                 { columns => [@buildListColumns, 'drvpath', 'description', 'homepage']
                 , join => ["buildoutputs"]
                 , order_by => ["build.id", "buildoutputs.name"]
                 , '+select' => ['buildoutputs.path', 'buildoutputs.name'], '+as' => ['outpath', 'outname'] });
}


sub job : Chained('evalChain') PathPart('job') {
    my ($self, $c, $job, @rest) = @_;

    my $build = $c->stash->{eval}->builds->find({job => $job});

    notFound($c, "This evaluation has no job with the specified name.") unless defined $build;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$build->id], @rest));
}


# Return the store paths of all succeeded builds of type 'nix-build'
# (i.e. regular packages). Used by the NixOS channel scripts.
sub store_paths : Chained('evalChain') PathPart('store-paths') Args(0) {
    my ($self, $c) = @_;

    my @builds = $c->stash->{eval}->builds
        ->search_literal("exists (select 1 from buildproducts where build = build.id and type = 'nix-build')")
        ->search({ finished => 1, buildstatus => 0 },
                 { columns => [], join => ["buildoutputs"]
                 , '+select' => ['buildoutputs.path'], '+as' => ['outpath'] });

    $self->status_ok(
        $c,
        entity => [uniq(sort map {$_->get_column('outpath')} @builds)]
    );
}


# Return full info about all the builds in this evaluation.
sub all_builds : Chained('evalChain') PathPart('builds') Args(0) {
    my ($self, $c) = @_;
    my @builds = $c->stash->{eval}->builds;
    $self->status_ok(
        $c,
        entity => [@builds],
    );
}


1;
