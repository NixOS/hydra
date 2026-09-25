package Hydra::Controller::BuildStep;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::LogEndpoints;
use WWW::Form::UrlEncoded::PP qw();


sub buildStepChain :Chained('/build/buildChain') :PathPart('step') :CaptureArgs(1) {
    my ($self, $c, $stepnr) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;
}


sub buildStep :Chained('buildStepChain') :PathPart('') :Args(0) :ActionClass('REST') { }

sub buildStep_GET {
    my ($self, $c) = @_;

    my $step = $c->stash->{step};
    if (defined $step->status && $step->status == 13 && $step->resolveddrvpath) {
        # Same shape as build_GET's stash, so renderStepStatus works here too.
        $c->stash->{resolvedTerminals} = { $step->stepnr => $step->resolved_terminal };
    } else {
        # Real steps may be the target of Resolved steps; link back to them.
        $c->stash->{resolutionOrigins} = $step->resolution_origins;
    }

    $c->stash->{template} = 'build-step.tt';

    $self->status_ok(
        $c,
        entity => $c->stash->{step}
    );
}


sub view_nixlog : Chained('buildStepChain') PathPart('log') {
    my ($self, $c, $mode) = @_;

    my $step = $c->stash->{step};

    # Resolved steps are pure redirections: they never build, so they have
    # no log. The step detail page links to the terminal step, whose own
    # log endpoint serves the actual build output.
    if (defined $step->status && $step->status == 13 && $step->resolveddrvpath) {
        notFound($c, "Build step " . $step->stepnr . " was resolved to another derivation and has no log of its own.");
    }

    my $log_uri = $c->uri_for($c->controller('Root')->action_for("log"),
        [WWW::Form::UrlEncoded::PP::url_encode($step->drvpath->to_string)]);
    showLog($c, $mode, $log_uri);
}


1;
