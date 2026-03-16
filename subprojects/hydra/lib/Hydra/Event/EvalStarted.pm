package Hydra::Event::EvalStarted;

use strict;
use warnings;

sub parse :prototype(@) {
    unless (@_ == 2) {
        die "eval_started: payload takes two arguments, but ", scalar(@_), " were given";
    }

    my ($trace_id, $jobset_id) = @_;

    unless ($jobset_id =~ /^\d+$/) {
        die "eval_started: payload argument should be an integer, but '", $jobset_id, "' was given"
    }

    return Hydra::Event::EvalStarted->new($trace_id, int($jobset_id));
}

sub new {
    my ($self, $trace_id, $jobset_id) = @_;
    return bless {
        "trace_id" => $trace_id,
        "jobset_id" => $jobset_id,
        "jobset" => undef
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('evalStarted')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"jobset"})) {
        $self->{"jobset"} = $db->resultset('Jobsets')->find({ id => $self->{"jobset_id"}})
            or die "Jobset $self->{'jobset_id'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->evalStarted($self->{"trace_id"}, $self->{"jobset"});

    return 1;
}

1;
