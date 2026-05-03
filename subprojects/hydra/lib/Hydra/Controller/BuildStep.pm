package Hydra::Controller::BuildStep;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::LogEndpoints;
use File::Basename;
use WWW::Form::UrlEncoded::PP qw();


sub buildStepChain :Chained('/build/buildChain') :PathPart('step') :CaptureArgs(1) {
    my ($self, $c, $stepnr) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;
}


sub buildStep : Chained('buildStepChain') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'build-step.tt';
}


sub view_nixlog : Chained('buildStepChain') PathPart('log') {
    my ($self, $c, $mode) = @_;

    my $drvPath = $c->stash->{step}->drvpath;
    my $log_uri = $c->uri_for($c->controller('Root')->action_for("log"), [WWW::Form::UrlEncoded::PP::url_encode(basename($drvPath))]);
    showLog($c, $mode, $log_uri);
}


1;
