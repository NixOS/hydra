package Hydra::Event::BuildStarted;

use strict;
use warnings;

sub parse :prototype(@) {
    unless (@_ == 1) {
        die "build_started: payload takes only one argument, but ", scalar(@_), " were given";
    }

    my ($build_id) = @_;

    unless ($build_id =~ /^\d+$/) {
        die "build_started: payload argument should be an integer, but '", $build_id, "' was given"
    }

    return Hydra::Event::BuildStarted->new(int($build_id));
}

sub new {
    my ($self, $id) = @_;
    return bless { "build_id" => $id }, $self;
}

1;
