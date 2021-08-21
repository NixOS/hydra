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
    my ($self, $build_id, $dependent_ids) = @_;
    return bless {
        "build_id" => $build_id,
        "dependent_ids" => $dependent_ids,
        "build" => undef,
        "dependents" => [],
    }, $self;
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"build"})) {
        $self->{"build"} = $db->resultset('Builds')->find($self->{"build_id"})
            or die "build $self->{'build_id'} does not exist\n";

        foreach my $id (@{$self->{"dependent_ids"}}) {
            my $dep = $db->resultset('Builds')->find($id)
                or die "dependent build $id does not exist\n";
            push @{$self->{"dependents"}}, $dep;
        }
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->buildFinished($self->{"build"}, $self->{"dependents"});

    # Mark the build and all dependents as having their notifications "finished".
    #
    # Otherwise, the dependent builds will remain with notificationpendingsince set
    # until hydra-notify is started, as buildFinished is never emitted for them.
    foreach my $build ($self->{"build"}, @{$self->{"dependents"}}) {
        if ($build->finished && defined($build->notificationpendingsince)) {
            $build->update({ notificationpendingsince => undef })
        }
    }

    return 1;
}

1;
