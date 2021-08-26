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

=cut

=head2 new

Arguments:

=over 1

=item C<$dbh>
L<DBI::db> The database connection.

=back

=item C<$prometheus>
L<Prometheus::Tiny> A Promethues implementation, either Prometheus::Tiny
or Prometheus::Tiny::Shared. Not compatible with Net::Prometheus.

=back

=item C<%plugins>
L<Hydra::Plugin> A list of Hydra plugins to execute events and tasks against.

=back

=cut

sub new {
    my ($self, $db, $prometheus, $plugins) = @_;

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

    my %plugins_by_name = map { ref $_ => $_ } @{$plugins};

    my $obj = bless {
        "db" => $db,
        "prometheus" => $prometheus,
        "plugins_by_name" => \%plugins_by_name,
    }, $self;
}

=head2 dispatch_event

Execute each configured plugin against the provided L<Hydra::Event>.

Arguments:

=over 1

=item C<$event>

L<Hydra::Event> the event, usually from L<Hydra::PostgresListener>.

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

Execute a specifi plugin against the provided L<Hydra::Task>.
The Task includes information about what plugin should be executed.
If the provided plugin does not exist, an error logged is logged and the
function returns falsey.

Arguments:

=over 1

=item C<$task>

L<Hydra::Task> the task, usually from L<Hydra::Shema::Result::TaskRetries>.

=back

=cut
sub dispatch_task {
    my ($self, $task) = @_;

    my $channel_name = $task->{"event"}->{'channel_name'};
    my $plugin_name = $task->{"plugin_name"};
    my $event_labels = {
        channel => $channel_name,
        plugin => $plugin_name,
    };

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
        1;
    } or do {
        $self->{"prometheus"}->inc("notify_plugin_error", $event_labels);
        print STDERR "error running $channel_name hooks: $@\n";
        return 0;
    }
}

1;
