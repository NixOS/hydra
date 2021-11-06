package Hydra::Schema::ResultSet::TaskRetries;

use strict;
use warnings;
use utf8;
use base 'DBIx::Class::ResultSet';
use List::Util qw(max);
use Hydra::Math qw(exponential_backoff);
use Hydra::Task;

=head2 get_seconds_to_next_retry

Query the database to identify how soon the next retryable task is due
for being attempted again.

If there are no tasks to be reattempted, it returns undef.

If a task's scheduled retry has passed, it returns 0.

Otherwise, returns the number of seconds to wait before looking for more work.

=cut
sub get_seconds_to_next_retry {
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

=head2 save_task

Save a failing L<Hydra::Task> in the database, with a retry scheduled
for a few seconds away.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> The failing task to retry.

=back

=cut
sub save_task {
    my ($self, $task) = @_;

    return $self->create({
        channel => $task->{"event"}->{"channel_name"},
        pluginname => $task->{"plugin_name"},
        payload => $task->{"event"}->{"payload"},
        attempts => 1,
        retry_at => time() + exponential_backoff(1),
    });
}

=head2 get_retryable_task
=cut
sub get_retryable_task {
    my ($self) = @_;

    my $row = $self->get_retryable_taskretries_row();
    if (!defined($row)) {
        return undef;
    }

    my $event = Hydra::Event->new_event(
        $row->get_column("channel"),
        $row->get_column("payload")
    );

    my $task = Hydra::Task->new($event, $row->get_column("pluginname"));
    $task->{"record"} = $row;

    return $task;
}


=head2 get_retryable_taskretries_row

Fetch the next task to retry.

=cut
sub get_retryable_taskretries_row {
    my ($self) = @_;

    my $next_retry = $self->search(
        {
            'retry_at' => { '<=', time() }
        }, # any task
        {
            order_by => {
                -asc => 'retry_at'
            },
            rows => 1,
        }
    )->first;
}

1;
