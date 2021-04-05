package Hydra::Event::BuildFinished;

use strict;
use warnings;

sub parse :prototype(@) {
    if (@_ == 0) {
        die "build_finished: payload takes at least one argument, but ", scalar(@_), " were given";
    }

    my @failures = grep(!/^\d+$/, @_);
    if (@failures > 0) {
        die "build_finished: payload arguments should be integers, but we received the following non-integers:", @failures;
    }

    my ($build_id, @dependents) = map int, @_;
    return Hydra::Event::BuildFinished->new($build_id, \@dependents);
}

sub new {
    my ($self, $build_id, $dependencies) = @_;
    return bless { "build_id" => $build_id, "dependencies" => $dependencies }, $self;
}

1;
