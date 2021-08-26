package Hydra::TaskDispatcher;

use strict;
use warnings;
use Hydra::Task;
use Time::HiRes qw( gettimeofday tv_interval );


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
    my $eventLabels = {
        channel => $channelName,
        plugin => $pluginName,
    };

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
        1;
    } or do {
        $self->{"prometheus"}->inc("notify_plugin_error", $eventLabels);
        print STDERR "error running $channelName hooks: $@\n";
        return 0;
    }
}

1;
