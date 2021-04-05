package Hydra::Event::StepFinished;

use strict;
use warnings;


sub parse :prototype(@) {
    unless (@_ == 3) {
        die "step_finished: payload takes exactly three arguments, but ", scalar(@_), " were given";
    }

    my ($build_id, $step_number, $log_path) = @_;

    unless ($build_id =~ /^\d+$/) {
        die "step_finished: payload argument build_id should be an integer, but '", $build_id, "' was given"
    }
    unless ($step_number =~ /^\d+$/) {
        die "step_finished: payload argument step_number should be an integer, but '", $step_number, "' was given"
    }

    return Hydra::Event::StepFinished->new(int($build_id), int($step_number), $log_path);
}

sub new :prototype($$$) {
    my ($self, $build_id, $step_number, $log_path) = @_;
    return bless { "build_id" => $build_id, "step_number" => $step_number, "log_path" => $log_path }, $self;
}

1;
