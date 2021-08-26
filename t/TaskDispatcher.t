use strict;
use warnings;
use Setup;

use Hydra::TaskDispatcher;
use Prometheus::Tiny::Shared;

use Test2::V0;
use Test2::Tools::Mock qw(mock_obj);

my $db = "bogus db";
my $prometheus  = Prometheus::Tiny::Shared->new;

sub makeFakePlugin {
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

subtest "dispatchEvent" => sub {
    subtest "every plugin gets called once" => sub {
        my @plugins = [makeFakePlugin("bogus-1"), makeFakePlugin("bogus-2")];

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
        my $bogusPlugin = makeFakePlugin("bogus-1");
        my @plugins = [$bogusPlugin, makeFakePlugin("bogus-2")];

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
};


done_testing;
