package Hydra::Controller::JobsetEval;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use List::MoreUtils qw(uniq);


sub evalChain : Chained('/') PathPart('eval') CaptureArgs(1) {
    my ($self, $c, $evalId) = @_;

    my $eval = $c->model('DB::JobsetEvals')->find($evalId)
        or notFound($c, "Evaluation $evalId doesn't exist.");

    $c->stash->{eval} = $eval;
    $c->stash->{project} = $eval->project;
    $c->stash->{jobset} = $eval->jobset;
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

    sub cmpBuilds {
        my ($a, $b) = @_;
        return $a->get_column('job') cmp $b->get_column('job')
            || $a->get_column('system') cmp $b->get_column('system')
    }

    my @builds = $eval->builds->search($filter, { columns => [@buildListColumns] });
    my @builds2 = defined $eval2 ? $eval2->builds->search($filter, { columns => [@buildListColumns] }) : ();

    @builds  = sort { cmpBuilds($a, $b) } @builds;
    @builds2 = sort { cmpBuilds($a, $b) } @builds2;

    $c->stash->{stillSucceed} = [];
    $c->stash->{stillFail} = [];
    $c->stash->{nowSucceed} = [];
    $c->stash->{nowFail} = [];
    $c->stash->{new} = [];
    $c->stash->{removed} = [];
    $c->stash->{unfinished} = [];
    $c->stash->{aborted} = [];

    my $n = 0;
    foreach my $build (@builds) {
        my $aborted = $build->finished != 0 && ($build->buildstatus == 3 || $build->buildstatus == 4);
        my $d;
        my $found = 0;
        while ($n < scalar(@builds2)) {
            my $build2 = $builds2[$n];
            my $d = cmpBuilds($build, $build2);
            last if $d == -1;
            if ($d == 0) {
                $n++;
                $found = 1;
                if ($aborted) {
                    # do nothing
                } elsif ($build->finished == 0 || $build2->finished == 0) {
                    push @{$c->stash->{unfinished}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{stillSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{stillFail}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{nowSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{nowFail}}, $build;
                } else { die; }
                last;
            }
            push @{$c->stash->{removed}}, { job => $build2->get_column('job'), system => $build2->get_column('system') };
            $n++;
        }
        if ($aborted) {
            push @{$c->stash->{aborted}}, $build;
        } else {
            push @{$c->stash->{new}}, $build if !$found;
        }
    }

    $c->stash->{full} = ($c->req->params->{full} || "0") eq "1";

    $self->status_ok(
        $c,
        entity => $eval
    );
}


sub release : Chained('evalChain') PathPart('release') Args(0) {
    my ($self, $c) = @_;
    my $eval = $c->stash->{eval};

    requireProjectOwner($c, $c->stash->{project});

    my @builds = $eval->builds;

    my $releaseName;
    $releaseName ||= $_->releasename foreach @builds;

    # If no release name has been defined by any of the builds, compose one of the project name and evaluation id
    $releaseName = $eval->get_column('project') . "-" . $eval->id unless defined $releaseName;

    my $release;

    txn_do($c->model('DB')->schema, sub {

        $release = $c->stash->{project}->releases->create(
            { name => $releaseName
            , timestamp => time
            });

        foreach my $build (@builds) {
            $release->releasemembers->create(
                { build => $build->id
                , description => $build->description
                }) if $build->buildstatus == 0;
        }
    });

    $c->res->redirect($c->uri_for($c->controller('Release')->action_for('view'),
        [$c->stash->{project}->name, $release->name]));
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
    requireProjectOwner($c, $c->stash->{eval}->project);
    my $n = cancelBuilds($c->model('DB')->schema, $c->stash->{eval}->builds);
    $c->flash->{successMsg} = "$n builds have been cancelled.";
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for('view'), $c->req->captures));
}


sub restart {
    my ($self, $c, $condition) = @_;
    requireRestartPrivileges($c, $c->stash->{eval}->project);
    my $builds = $c->stash->{eval}->builds->search({ finished => 1, buildstatus => $condition });
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
    requireProjectOwner($c, $c->stash->{eval}->project); # FIXME: require admin?
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
