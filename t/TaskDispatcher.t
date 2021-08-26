use strict;
use warnings;
use Setup;

use Hydra::TaskDispatcher;
use Prometheus::Tiny::Shared;

use Test2::V0;
use Test2::Tools::Mock qw(mock_obj);

my $db = "bogus db";
my $prometheus  = Prometheus::Tiny::Shared->new;

sub makeNoopPlugin {
    my ($name) = @_;
    my $plugin = {
        "name" => $name,
    };
    my $mock_plugin = mock_obj $plugin => ();

    return $mock_plugin;
}

sub makeFakeEvent {
    my ($channel_name) = @_;

    my $event = {
        channel_name => $channel_name,
        called_with => [],
    };
    my $mock_event = mock_obj $event => (
        add => [
            "execute" => sub {
                my ($self, $db, $plugin) = @_;
                push @{$self->{"called_with"}}, $plugin;
            }
        ]
    );

    return $mock_event;
}

sub makeFailingEvent {
    my ($channel_name) = @_;

    my $event = {
        channel_name => $channel_name,
    };
    my $mock_event = mock_obj $event => (
        add => [
            "execute" => sub {
                my ($self, $db, $plugin) = @_;
                die "Failing plugin."
            }
        ]
    );

    return $mock_event;
}

sub makeFakeRecord {
   my %attrs = @_;

    my $record = {
        "attempts" => $attrs{"attempts"} || 0,
        "requeued" => 0,
        "deleted" => 0
    };

    my $mock_record = mock_obj $record => (
        add => [
            "delete" => sub {
                my ($self, $db, $plugin) = @_;
                $self->{"deleted"} = 1;
            },
            "requeue" => sub {
                my ($self, $db, $plugin) = @_;
                $self->{"requeued"} = 1;
            }
        ]
    );

    return $mock_record;
}

subtest "dispatchEvent" => sub {
    subtest "every plugin gets called once" => sub {
        my @plugins = [makeNoopPlugin("bogus-1"), makeNoopPlugin("bogus-2")];

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, @plugins);

        my $event = makeFakeEvent("bogus-channel");
        $dispatcher->dispatchEvent($event);

        is(@{$event->{"called_with"}}, 2, "Both plugins should be called");

        my @expected_names = [ "bogus-1", "bogus-2" ];
        my @actual_names = sort([
                $event->{"called_with"}[0]->name,
                $event->{"called_with"}[1]->name
        ]);

        is(
            @actual_names,
            @expected_names,
            "Both plugins should be executed, but not in any particular order."
        );
    };
};

subtest "dispatchTask" => sub {
    subtest "every plugin gets called once" => sub {
        my $bogusPlugin = makeNoopPlugin("bogus-1");
        my @plugins = [$bogusPlugin, makeNoopPlugin("bogus-2")];

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, @plugins);

        my $event = makeFakeEvent("bogus-channel");
        my $task = Hydra::Task->new($event, ref $bogusPlugin);
        $dispatcher->dispatchTask($task);

        is(@{$event->{"called_with"}}, 1, "Just one plugin should be called");

        is(
            $event->{"called_with"}[0]->name,
            "bogus-1",
            "Just bogus-1 should be executed."
        );
    };

    subtest "a successful run from a record deletes the record" => sub {
        my $db = "bogus db";

        my $record = makeFakeRecord();
        my $bogusPlugin = makeNoopPlugin("bogus-1");
        my $task = {
            "event" => makeFakeEvent("success-event"),
            "plugin_name" => ref $bogusPlugin,
            "record" => $record,
        };

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, [$bogusPlugin]);
        $dispatcher->dispatchTask($task);

        is($record->{"deleted"}, 1, "The record was deleted.");
    };

    subtest "a failed run from a record re-queues the task" => sub {
        my $db = "bogus db";

        my $record = makeFakeRecord();
        my $bogusPlugin = makeNoopPlugin("bogus-1");
        my $task = {
            "event" => makeFailingEvent("fail-event"),
            "plugin_name" => ref $bogusPlugin,
            "record" => $record,
        };

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, [$bogusPlugin]);
        $dispatcher->dispatchTask($task);

        is($record->{"requeued"}, 1, "The record was requeued.");
    };

    subtest "a failed run from a record with a lot of attempts deletes the task" => sub {
        my $db = "bogus db";

        my $record = makeFakeRecord(attempts => 101);

        my $bogusPlugin = makeNoopPlugin("bogus-1");
        my $task = {
            "event" => makeFailingEvent("fail-event"),
            "plugin_name" => ref $bogusPlugin,
            "record" => $record,
        };

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, [$bogusPlugin]);
        $dispatcher->dispatchTask($task);

        is($record->{"deleted"}, 1, "The record was deleted.");
    };
};


done_testing;
