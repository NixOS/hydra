package Hydra::View::TT;

use strict;
use base 'Catalyst::View::TT';
use Hydra::Helper::Nix;
use Time::Seconds;

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    ENCODING => 'utf-8',
    PRE_CHOMP => 1,
    POST_CHOMP => 1,
    expose_methods => [qw/buildLogExists buildStepLogExists jobExists relativeDuration stripSSHUser/]);

sub buildLogExists {
    my ($self, $c, $build) = @_;
    return 1 if defined $c->config->{log_prefix};
    my @outPaths = map { $_->path } $build->buildoutputs->all;
    return defined findLog($c, $build->drvpath, @outPaths);
}

sub buildStepLogExists {
    my ($self, $c, $step) = @_;
    return 1 if defined $c->config->{log_prefix};
    my @outPaths = map { $_->path } $step->buildstepoutputs->all;
    return defined findLog($c, $step->drvpath, @outPaths);
}

=head2 relativeDuration

Given an integer of seconds, return an English representation of the
duration as a string.

Arguments:

=over 1

=item C<$seconds>

An integer number of seconds

=back

=cut
sub relativeDuration {
    my ($self, $c, $seconds) = @_;
    return Time::Seconds->new($seconds)->pretty();
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
    my ($self, $c, $jobset, $jobName) = @_;
    return defined $jobset->builds->search({ job => $jobName, iscurrent => 1 })->single;
}

1;
