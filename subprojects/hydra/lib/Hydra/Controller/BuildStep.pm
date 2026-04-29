package Hydra::Controller::BuildStep;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::LogEndpoints;
use Hydra::Helper::Nix;
use File::Basename;
use WWW::Form::UrlEncoded::PP qw();


sub buildStepChain :Chained('/build/buildChain') :PathPart('step') :CaptureArgs(1) {
    my ($self, $c, $stepnr) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;
}


# Classify a Resolved step (status=13) into pending state + terminal info.
sub _resolvedStepInfo {
    my ($c, $step) = @_;

    my ($terminal, $chain) = followResolvedChain($c, $step);
    my $isSelf = $terminal
        && $terminal->get_column('build') == $c->stash->{build}->id
        && $terminal->stepnr == $step->stepnr;

    my $state;
    if (!$isSelf) {
        if ($terminal && $terminal->busy) {
            $state = 'running';
        } elsif ($terminal && defined $terminal->status && $terminal->status == 13) {
            $state = 'dead-end';
        } else {
            $state = 'unscheduled';
        }
    } else {
        my $chainSize = scalar @{ $chain // [] };
        my $directSelfCycle = $chainSize == 1
            && $step->drvpath && $step->resolveddrvpath
            && basename($step->drvpath) eq $step->resolveddrvpath;
        $state = ($chainSize >= 2 || $directSelfCycle) ? 'cycle' : 'unscheduled';
    }

    return ($terminal, $chain, $isSelf, $state);
}


sub buildStep : Chained('buildStepChain') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $step = $c->stash->{step};
    if (defined $step->status && $step->status == 13 && $step->resolveddrvpath) {
        my ($terminal, $chain, $isSelf, $state) = _resolvedStepInfo($c, $step);
        $c->stash->{resolvedPending} = {
            chain    => $chain,
            terminal => (!$isSelf ? $terminal : undef),
            state    => $state,
        };
    }

    $c->stash->{template} = 'build-step.tt';
}


sub view_nixlog : Chained('buildStepChain') PathPart('log') {
    my ($self, $c, $mode) = @_;

    my $step = $c->stash->{step};

    # Resolved steps have no log of their own. Try terminal step's log; else
    # fall back to the step detail page where pending state is rendered.
    if (defined $step->status && $step->status == 13 && $step->resolveddrvpath) {
        my ($terminal, undef, $isSelf, undef) = _resolvedStepInfo($c, $step);
        if ($terminal && !$isSelf
            && defined $terminal->status && $terminal->status != 13
            && $terminal->busy == 0)
        {
            my @path = ('/build', $terminal->get_column('build'), 'step', $terminal->stepnr, 'log');
            push @path, $mode if defined $mode;
            $c->res->redirect($c->uri_for(@path));
            return;
        }
        $c->res->redirect($c->uri_for('/build', $c->stash->{id}, 'step', $step->stepnr));
        return;
    }

    my $drvPath = $step->drvpath;

    # Surface every Resolved step that landed at this drv (if any) on pretty pages.
    if (!defined $mode) {
        my $origins = findResolutionOrigins($c, $c->stash->{build}->id, $drvPath);
        if (@$origins) {
            $c->stash->{resolutionOrigins} = [
                map { {
                    build       => $_->{origin}->get_column('build'),
                    stepnr      => $_->{origin}->stepnr,
                    chain       => $_->{chain},
                    origDrvPath => $_->{origDrvPath},
                } } @$origins
            ];
        }
    }

    my $log_uri = $c->uri_for($c->controller('Root')->action_for("log"), [WWW::Form::UrlEncoded::PP::url_encode(basename($drvPath))]);
    showLog($c, $mode, $log_uri);
}


1;
