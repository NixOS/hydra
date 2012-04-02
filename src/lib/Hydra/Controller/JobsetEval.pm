package Hydra::Controller::JobsetEval;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub eval : Chained('/') PathPart('eval') CaptureArgs(1) {
    my ($self, $c, $evalId) = @_;
    
    my $eval = $c->model('DB::JobsetEvals')->find($evalId)
	or notFound($c, "Evaluation $evalId doesn't exist.");

    $c->stash->{eval} = $eval;
    $c->stash->{project} = $eval->project;
    $c->stash->{jobset} = $eval->jobset;
}


sub view : Chained('eval') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset-eval.tt';

    my $eval = $c->stash->{eval};

    my ($eval2) = $eval->jobset->jobsetevals->search(
        { hasnewbuilds => 1, id => { '<', $eval->id } },
        { order_by => "id DESC", rows => 1 });

    my @builds = $eval->builds->search({}, { order_by => ["job", "system", "id"], columns => [@buildListColumns] });
    my @builds2 = $eval2->builds->search({}, { order_by => ["job", "system", "id"], columns => [@buildListColumns] });

    print STDERR "EVAL IS ", $eval2->id, "\n";
    print STDERR scalar(@builds), "\n";
    print STDERR scalar(@builds2), "\n";

    $c->stash->{stillSucceed} = [];
    $c->stash->{stillFail} = [];
    $c->stash->{nowSucceed} = [];
    $c->stash->{nowFail} = [];

    my $n = 0;
    foreach my $build (@builds) {
        my $d;
        while ($n < scalar(@builds2)) {
            my $build2 = $builds2[$n];
            my $d = $build->get_column('job') cmp $build2->get_column('job')
                || $build->get_column('system') cmp $build2->get_column('system');
            #print STDERR $build->id, " ", $build->get_column('job'), " ",  $build->system, " ", $d, "\n";
            last if $d == -1;
            if ($d == 0) {
                #print STDERR $build->buildstatus, "\n";
                #print STDERR $build2->buildstatus, "\n";
                if ($build->buildstatus == 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{stillSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{stillFail}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{nowSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{nowFail}}, $build;
                }
                last;
            }
            $n++;
        }
    }
    
    $c->stash->{full} = ($c->req->params->{full} || "0") eq "1";
}


1;
