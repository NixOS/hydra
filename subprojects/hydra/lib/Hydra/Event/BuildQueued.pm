package Hydra::Event::BuildQueued;

use strict;
use warnings;

sub parse :prototype(@) {
    unless (@_ == 1) {
        die "build_queued: payload takes only one argument, but ", scalar(@_), " were given";
    }

    my ($build_id) = @_;

    unless ($build_id =~ /^\d+$/) {
        die "build_queued: payload argument should be an integer, but '", $build_id, "' was given"
    }

    return Hydra::Event::BuildQueued->new(int($build_id));
}

sub new {
    my ($self, $id) = @_;
    return bless {
        "build_id" => $id,
        "build" => undef
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('buildQueued')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"build"})) {
        $self->{"build"} = $db->resultset('Builds')->find($self->{"build_id"})
            or die "build $self->{'build_id'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->buildQueued($self->{"build"});

    return 1;
}

1;
