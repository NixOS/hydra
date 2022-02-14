package Hydra::Event::StepFinished;

use strict;
use warnings;

sub parse : prototype(@) {
    unless (@_ == 3) {
        die "step_finished: payload takes exactly three arguments, but ", scalar(@_), " were given";
    }

    my ($build_id, $step_number, $log_path) = @_;

    unless ($build_id =~ /^\d+$/) {
        die "step_finished: payload argument build_id should be an integer, but '", $build_id, "' was given";
    }
    unless ($step_number =~ /^\d+$/) {
        die "step_finished: payload argument step_number should be an integer, but '", $step_number, "' was given";
    }

    return Hydra::Event::StepFinished->new(int($build_id), int($step_number), $log_path);
}

sub new : prototype($$$) {
    my ($self, $build_id, $step_number, $log_path) = @_;

    $log_path = undef if $log_path eq "-";

    return bless {
        "build_id"    => $build_id,
        "step_number" => $step_number,
        "log_path"    => $log_path,
        "step"        => undef,
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('stepFinished')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"step"})) {
        my $build = $db->resultset('Builds')->find($self->{"build_id"})
          or die "build $self->{'build_id'} does not exist\n";

        $self->{"step"} = $build->buildsteps->find({ stepnr => $self->{"step_number"} })
          or die "step $self->{'step_number'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->stepFinished($self->{"step"}, $self->{"log_path"});

    return 1;
}

1;
