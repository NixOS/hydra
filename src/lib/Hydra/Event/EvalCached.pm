package Hydra::Event::EvalCached;

use strict;
use warnings;

sub parse :prototype(@) {
    unless (@_ == 3) {
        die "eval_cached: payload takes exactly three arguments, but ", scalar(@_), " were given";
    }

    my ($trace_id, $jobset_id, $evaluation_id) = @_;

    unless ($jobset_id =~ /^\d+$/) {
        die "eval_cached: payload argument jobset_id should be an integer, but '", $jobset_id, "' was given"
    }
    unless ($evaluation_id =~ /^\d+$/) {
        die "eval_cached: payload argument evaluation_id should be an integer, but '", $evaluation_id, "' was given"
    }

    return Hydra::Event::EvalCached->new($trace_id, int($jobset_id), int($evaluation_id));
}

sub new {
    my ($self, $trace_id, $jobset_id, $evaluation_id) = @_;
    return bless {
        "trace_id" => $trace_id,
        "jobset_id" => $jobset_id,
        "evaluation_id" => $evaluation_id,
        "jobset" => undef,
        "evaluation" => undef
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('evalCached')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"jobset"})) {
        $self->{"jobset"} = $db->resultset('Jobsets')->find({ id => $self->{"jobset_id"}})
            or die "Jobset $self->{'jobset_id'} does not exist\n";
    }

    if (!defined($self->{"evaluation"})) {
        $self->{"evaluation"} = $db->resultset('JobsetEvals')->find({ id => $self->{"evaluation_id"}})
            or die "Jobset $self->{'jobset_id'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->evalCached($self->{"trace_id"}, $self->{"jobset"}, $self->{"evaluation"});

    return 1;
}

1;
