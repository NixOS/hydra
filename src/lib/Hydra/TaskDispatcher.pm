package Hydra::TaskDispatcher;

use strict;
use warnings;
use Hydra::Task;
use Time::HiRes qw( gettimeofday tv_interval );


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

    my $obj = bless {
        "db" => $db,
        "prometheus" => $prometheus,
        "plugins_by_name" => \%plugins_by_name,
        "store_task" => $store_task,
    }, $self;
}

sub dispatchEvent {
    my ($self, $event) = @_;

    foreach my $pluginName (keys %{$self->{"plugins_by_name"}}) {
        my $task = Hydra::Task->new($event, $pluginName);
        $self->dispatchTask($task);
    }
}

sub dispatchTask {
    my ($self, $task) = @_;

    my $channelName = $task->{"event"}->{'channel_name'};
    my $pluginName = $task->{"plugin_name"};
    my $eventLabels = $self->promLabelsForTask($task);

    my $plugin = $self->{"plugins_by_name"}->{$pluginName};

    if (!defined($plugin)) {
        $self->{"prometheus"}->inc("notify_plugin_no_such_plugin", $eventLabels);
        print STDERR "No plugin named $self->{'plugin_name'}\n";
        return 0;
    }

    $self->{"prometheus"}->inc("notify_plugin_executions", $eventLabels);
    eval {
        my $startTime = [gettimeofday()];

        $task->{"event"}->execute($self->{"db"}, $plugin);

        $self->{"prometheus"}->histogram_observe("notify_plugin_runtime", tv_interval($startTime), $eventLabels);
        $self->{"prometheus"}->inc("notify_plugin_success", $eventLabels);
        $self->success($task);
        1;
    } or do {
        $self->failure($task);
        $self->{"prometheus"}->inc("notify_plugin_error", $eventLabels);
        print STDERR "error running $channelName hooks: $@\n";
        return 0;
    }
}

sub promLabelsForTask {
    my ($self, $task) = @_;

    my $channelName = $task->{"event"}->{'channel_name'};
    my $pluginName = $task->{"plugin_name"};
    return {
        channel => $channelName,
        plugin => $pluginName,
    };
}

sub success {
    my ($self, $task) = @_;

    my $eventLabels = $self->promLabelsForTask($task);

    if (defined($task->{"record"})) {
        $self->{"prometheus"}->inc("notify_plugin_retry_sucess", $eventLabels);
        $task->{"record"}->delete();
    }
}

sub failure {
    my ($self, $task) = @_;

    my $eventLabels = $self->promLabelsForTask($task);

    if (defined($task->{"record"})) {
        if ($task->{"record"}->{"attempts"} > 100) {
            $self->{"prometheus"}->inc("notify_plugin_drop", $eventLabels);
            $task->{"record"}->delete();
        } else {
            $self->{"prometheus"}->inc("notify_plugin_requeue", $eventLabels);
            $task->{"record"}->requeue();
        }
    } else {
        $self->{"store_task"}($task);
    }
}
1;
