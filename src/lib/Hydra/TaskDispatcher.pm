package Hydra::TaskDispatcher;

use strict;
use warnings;
use Hydra::Task;
use Time::HiRes qw( gettimeofday tv_interval );

=head1 Hydra::TaskDispatcher

Excecute many plugins with Hydra::Event as its input.

The TaskDispatcher is responsible for dealing with fanout
from one incoming Event being executed across many plugins,
or one Event being executed against a single plugin by first
wrapping it in a Task.

Its execution model is based on creating a Hydra::Task for
each plugin's execution. The task represents the name of
the plugin to run and the Event to process.

The dispatcher's behavior is slightly different based on
if the Task has an associated record:

=over 1

=item *
If a task succeeds and there is no record, the Dispatcher
assumes there is no further accounting of the task to be
done.

=item *
If a task succeeds and there is a record, the Dispatcher
calls C<delete> on the record.

=item *
If a task fails and there is no record, the Dispatcher
calls C<$store_task> with the Task as its only argument.
It is the C<$store_task>'s responsibility to store the
task in some way for retrying.

=item *
If a task fails and there is a record, the Dispatcher
calls C<requeue> on the record.

=back

=cut

=head2 new

Arguments:

=over 1

=item C<$dbh>
L<DBI::db> The database connection.

=item C<$prometheus>
L<Prometheus::Tiny> A Promethues implementation, either Prometheus::Tiny
or Prometheus::Tiny::Shared. Not compatible with Net::Prometheus.

=item C<%plugins>
L<Hydra::Plugin> A list of Hydra plugins to execute events and tasks against.

=item C<$store_task> (Optional)
A sub to call when storing a task for the first time. This sub is called
after a L<Hydra::Task>'s execution fails without an associated record.
The sub is called with the failing task, and is responsible for storing
the task for another attempt.

If no C<$store_task> sub is provided, all failed events are dropped.

=back

=cut

sub new {
    my ($self, $db, $prometheus, $plugins, $store_task) = @_;

    $prometheus->declare(
        "notify_plugin_executions",
        type => "counter",
        help => "Number of times each plugin has been called by channel."
    );
    $prometheus->declare(
        "notify_plugin_runtime",
        type => "histogram",
        help => "Number of seconds spent executing each plugin by channel."
    );
    $prometheus->declare(
        "notify_plugin_success",
        type => "counter",
        help => "Number of successful executions of this plugin on this channel."
    );
    $prometheus->declare(
        "notify_plugin_error",
        type => "counter",
        help => "Number of failed executions of this plugin on this channel."
    );
    $prometheus->declare(
        "notify_plugin_retry_success",
        type => "counter",
        help => "Number of successful executions of retried tasks."
    );
    $prometheus->declare(
        "notify_plugin_drop",
        type => "counter",
        help => "Number of tasks that have been dropped after too many retries."
    );
    $prometheus->declare(
        "notify_plugin_requeue",
        type => "counter",
        help => "Number of tasks that have been requeued after a failure."
    );

    my %plugins_by_name = map { ref $_ => $_ } @{$plugins};

    if (!defined($store_task)) {
        $store_task = sub {};
    }

    my $obj = bless {
        "db" => $db,
        "prometheus" => $prometheus,
        "plugins_by_name" => \%plugins_by_name,
        "store_task" => $store_task,
    }, $self;
}

=head2 dispatch_event

Execute each configured plugin against the provided L<Hydra::Event>.

Arguments:

=over 1

=item C<$event>

L<Hydra::Event> The event, usually from L<Hydra::PostgresListener>.

=back

=cut

sub dispatch_event {
    my ($self, $event) = @_;

    foreach my $plugin_name (keys %{$self->{"plugins_by_name"}}) {
        my $task = Hydra::Task->new($event, $plugin_name);
        $self->dispatch_task($task);
    }
}

=head2 dispatch_task

Execute a specific plugin against the provided L<Hydra::Task>.
The Task includes information about what plugin should be executed.
If the provided plugin does not exist, an error logged is logged and the
function returns falsey.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> The task, usually from L<Hydra::Shema::Result::TaskRetries>.

=back

=cut
sub dispatch_task {
    my ($self, $task) = @_;

    my $channel_name = $task->{"event"}->{'channel_name'};
    my $plugin_name = $task->{"plugin_name"};
    my $event_labels = $self->prom_labels_for_task($task);

    my $plugin = $self->{"plugins_by_name"}->{$plugin_name};

    if (!defined($plugin)) {
        $self->{"prometheus"}->inc("notify_plugin_no_such_plugin", $event_labels);
        print STDERR "No plugin named $plugin_name\n";
        return 0;
    }

    $self->{"prometheus"}->inc("notify_plugin_executions", $event_labels);
    eval {
        my $start_time = [gettimeofday()];

        $task->{"event"}->execute($self->{"db"}, $plugin);

        $self->{"prometheus"}->histogram_observe("notify_plugin_runtime", tv_interval($start_time), $event_labels);
        $self->{"prometheus"}->inc("notify_plugin_success", $event_labels);
        $self->success($task);
        1;
    } or do {
        $self->failure($task);
        $self->{"prometheus"}->inc("notify_plugin_error", $event_labels);
        print STDERR "error running $channel_name hooks: $@\n";
        return 0;
    }
}

=head2 success

Mark a task's execution as successful.

If the task has an associated record, the record is deleted.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> The task to mark as successful.

=back

=cut
sub success {
    my ($self, $task) = @_;

    my $event_labels = $self->prom_labels_for_task($task);

    if (defined($task->{"record"})) {
        $self->{"prometheus"}->inc("notify_plugin_retry_sucess", $event_labels);
        $task->{"record"}->delete();
    }
}

=head2 failure

Mark a task's execution as failed.

The task is requeued if it has been attempted fewer than than 100 times.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> The task to mark as successful.

=back

=cut
sub failure {
    my ($self, $task) = @_;

    my $event_labels = $self->prom_labels_for_task($task);

    if (defined($task->{"record"})) {
        if ($task->{"record"}->attempts > 100) {
            $self->{"prometheus"}->inc("notify_plugin_drop", $event_labels);
            $task->{"record"}->delete();
        } else {
            $self->{"prometheus"}->inc("notify_plugin_requeue", $event_labels);
            $task->{"record"}->requeue();
        }
    } else {
        $self->{"prometheus"}->inc("notify_plugin_requeue", $event_labels);
        $self->{"store_task"}($task);
    }
}

=head2 prom_labels_for_task

Given a specific task, return a hash of standard labels to record with
Prometheus.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> The task to return labels for.

=back

=cut
sub prom_labels_for_task {
    my ($self, $task) = @_;

    my $channel_name = $task->{"event"}->{'channel_name'};
    my $plugin_name = $task->{"plugin_name"};
    return {
        channel => $channel_name,
        plugin => $plugin_name,
    };
}

1;
