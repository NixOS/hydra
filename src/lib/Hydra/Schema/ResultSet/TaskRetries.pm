package Hydra::Schema::ResultSet::TaskRetries;

use strict;
use warnings;
use utf8;
use base 'DBIx::Class::ResultSet';
use List::Util qw(max);
use Hydra::Math qw(exponential_backoff);
use Hydra::Task;

sub getSecondsToNextRetry {
    my ($self) = @_;

    my $next_retry = $self->search(
        {}, # any task
        {
            order_by => {
                -asc => 'retry_at'
            },
            rows => 1,
        }
    )->get_column('retry_at')->first;

    if (defined($next_retry)) {
        return max(0, $next_retry - time());
    } else {
        return undef;
    }
}

sub getRetryableTask {
    my ($self) = @_;

    my $next_task = $self->find(
        {
            'retry_at' => { '<=', time() },
        },
        {
            order_by => {
                -asc => 'retry_at'
            },
            rows => 1,
        }
    );

    if (defined($next_task)) {
        my $event = Hydra::Event->new_event($next_task->channel, $next_task->payload);
        my $task = Hydra::Task->new($event, $next_task->pluginname);
        $task->{"record"} = $next_task;

        return $task
    } else {
        return undef;
    }
}

sub saveTask {
    my ($self, $task) = @_;

    return $self->create({
        channel => $task->{"event"}->{"channel_name"},
        pluginname => $task->{"plugin_name"},
        payload => $task->{"event"}->{"payload"},
        attempts => 1,
        retry_at => time() + exponential_backoff(1),
    });
}

1;
