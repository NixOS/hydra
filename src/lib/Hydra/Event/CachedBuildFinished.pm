package Hydra::Event::CachedBuildFinished;

use strict;
use warnings;

sub parse : prototype(@) {
    if (@_ != 2) {
        die "cached_build_finished: payload takes two arguments, but ", scalar(@_), " were given";
    }

    my @failures = grep(!/^\d+$/, @_);
    if (@failures > 0) {
        die "cached_build_finished: payload arguments should be integers, but we received the following non-integers:",
          @failures;
    }

    my ($evaluation_id, $build_id) = map int, @_;
    return Hydra::Event::CachedBuildFinished->new($evaluation_id, $build_id);
}

sub new {
    my ($self, $evaluation_id, $build_id) = @_;
    return bless {
        "evaluation_id" => $evaluation_id,
        "build_id"      => $build_id,
        "evaluation"    => undef,
        "build"         => undef,
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('cachedBuildFinished')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"build"})) {
        $self->{"build"} = $db->resultset('Builds')->find($self->{"build_id"})
          or die "build $self->{'build_id'} does not exist\n";
    }

    if (!defined($self->{"evaluation"})) {
        $self->{"evaluation"} = $db->resultset('JobsetEvals')->find($self->{"evaluation_id"})
          or die "evaluation $self->{'evaluation_id'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->cachedBuildFinished($self->{"evaluation"}, $self->{"build"});

    return 1;
}

1;
