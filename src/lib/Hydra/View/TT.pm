package Hydra::View::TT;

use strict;
use base 'Catalyst::View::TT';
use Hydra::Helper::Nix;

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    ENCODING => 'utf-8',
    PRE_CHOMP => 1,
    POST_CHOMP => 1,
    expose_methods => [qw/buildLogExists buildStepLogExists jobExists stripSSHUser/]);

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


sub stripSSHUser {
    my ($self, $c, $name) = @_;
    if ($name =~ /^.*@(.*)$/) {
        return $1;
    } else {
        return $name;
    }
}

# Check whether the given job is a member of the most recent jobset
# evaluation.
sub jobExists {
    my ($self, $c, $job) = @_;
    my $latestEval = $job->jobset->jobsetevals->search(
        { hasnewbuilds => 1},
        { rows => 1, order_by => ["id desc"] })->single;
    return 0 if !defined $latestEval; # can't happen
    return scalar($latestEval->builds->search({ job => $job->name })) != 0;
}

1;
