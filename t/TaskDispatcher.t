use strict;
use warnings;
use Setup;

use Hydra::TaskDispatcher;
use Prometheus::Tiny::Shared;

use Test2::V0;
use Test2::Tools::Mock qw(mock_obj);

my $db = "bogus db";
my $prometheus  = Prometheus::Tiny::Shared->new;

sub make_noop_plugin {
    my ($name) = @_;
    my $plugin = {
        "name" => $name,
    };
    my $mock_plugin = mock_obj $plugin => ();

    return $mock_plugin;
}

sub make_fake_event {
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

sub make_failing_event {
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
                die "Failing plugin."
            }
        ]
    );

    return $mock_event;
}

subtest "dispatch_event" => sub {
    subtest "every plugin gets called once, even if it fails all of them." => sub {
        my @plugins = [make_noop_plugin("bogus-1"), make_noop_plugin("bogus-2")];

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, @plugins);

        my $event = make_failing_event("bogus-channel");
        $dispatcher->dispatch_event($event);

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

subtest "dispatch_task" => sub {
    subtest "every plugin gets called once" => sub {
        my $bogus_plugin = make_noop_plugin("bogus-1");
        my @plugins = [$bogus_plugin, make_noop_plugin("bogus-2")];

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, @plugins);

        my $event = make_fake_event("bogus-channel");
        my $task = Hydra::Task->new($event, ref $bogus_plugin);
        is($dispatcher->dispatch_task($task), 1, "Calling dispatch_task returns truthy.");

        is(@{$event->{"called_with"}}, 1, "Just one plugin should be called");

        is(
            $event->{"called_with"}[0]->name,
            "bogus-1",
            "Just bogus-1 should be executed."
        );
    };
    subtest "a task with an invalid plugin is not fatal" => sub {
        my $bogus_plugin = make_noop_plugin("bogus-1");
        my @plugins = [$bogus_plugin, make_noop_plugin("bogus-2")];

        my $dispatcher = Hydra::TaskDispatcher->new($db, $prometheus, @plugins);

        my $event = make_fake_event("bogus-channel");
        my $task = Hydra::Task->new($event, "this-plugin-does-not-exist");
        is($dispatcher->dispatch_task($task), 0, "Calling dispatch_task returns falsey.");

        is(@{$event->{"called_with"}}, 0, "No plugins are called");
    };
};


done_testing;
