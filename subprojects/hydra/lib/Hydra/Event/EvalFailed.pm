package Hydra::Event::EvalFailed;

use strict;
use warnings;

sub parse :prototype(@) {
    unless (@_ == 3) {
        die "eval_failed: payload takes three arguments, but ", scalar(@_), " were given";
    }

    my ($trace_id, $jobset_id, $error_changed) = @_;

    unless ($jobset_id =~ /^\d+$/) {
        die "eval_failed: payload argument should be an integer, but '", $jobset_id, "' was given"
    }
    unless ($error_changed =~ /^[01]$/) {
        die "eval_failed: payload argument error_changed should be 0 or 1, but '", $error_changed, "' was given"
    }

    return Hydra::Event::EvalFailed->new($trace_id, int($jobset_id), int($error_changed));
}

sub new {
    my ($self, $trace_id, $jobset_id, $error_changed) = @_;
    return bless {
        "trace_id" => $trace_id,
        "jobset_id" => $jobset_id,
        "error_changed" => $error_changed,
        "jobset" => undef
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;
    return int(defined($plugin->can('evalFailed')));
}

sub load {
    my ($self, $db) = @_;

    if (!defined($self->{"jobset"})) {
        # `find_with_error`, not `find`: the jobset resultset leaves `errormsg`
        # out unless asked, and reporting the error is the whole point here.
        $self->{"jobset"} = $db->resultset('Jobsets')->find_with_error($self->{"jobset_id"})
            or die "Jobset $self->{'jobset_id'} does not exist\n";
    }
}

sub execute {
    my ($self, $db, $plugin) = @_;

    $self->load($db);

    $plugin->evalFailed($self->{"trace_id"}, $self->{"jobset"}, $self->{"error_changed"});

    return 1;
}

1;
