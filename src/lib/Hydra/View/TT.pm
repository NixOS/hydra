package Hydra::View::TT;

use strict;
use base 'Catalyst::View::TT';
use Hydra::Helper::Nix;

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    PRE_CHOMP => 1,
    POST_CHOMP => 1,
    expose_methods => [qw/log_exists buildLogExists buildStepLogExists/]);

sub log_exists {
    my ($self, $c, $drvPath) = @_;
    my $x = getDrvLogPath($drvPath);
    return defined $x;
}

sub buildLogExists {
    my ($self, $c, $build) = @_;
    my @outPaths = map { $_->path } $build->buildoutputs->all;
    return defined findLog($c, $build->drvpath, @outPaths);
}

sub buildStepLogExists {
    my ($self, $c, $step) = @_;
    my @outPaths = map { $_->path } $step->buildstepoutputs->all;
    return defined findLog($c, $step->drvpath, @outPaths);
}

1;
