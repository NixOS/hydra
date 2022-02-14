package Hydra::Event;

use strict;
use warnings;
use Hydra::Event::BuildFinished;
use Hydra::Event::BuildQueued;
use Hydra::Event::BuildStarted;
use Hydra::Event::CachedBuildFinished;
use Hydra::Event::CachedBuildQueued;
use Hydra::Event::EvalAdded;
use Hydra::Event::EvalCached;
use Hydra::Event::EvalFailed;
use Hydra::Event::EvalStarted;
use Hydra::Event::StepFinished;

my %channels_to_events = (
    build_finished        => \&Hydra::Event::BuildFinished::parse,
    build_queued          => \&Hydra::Event::BuildQueued::parse,
    build_started         => \&Hydra::Event::BuildStarted::parse,
    cached_build_finished => \&Hydra::Event::CachedBuildFinished::parse,
    cached_build_queued   => \&Hydra::Event::CachedBuildQueued::parse,
    eval_added            => \&Hydra::Event::EvalAdded::parse,
    eval_cached           => \&Hydra::Event::EvalCached::parse,
    eval_failed           => \&Hydra::Event::EvalFailed::parse,
    eval_started          => \&Hydra::Event::EvalStarted::parse,
    step_finished         => \&Hydra::Event::StepFinished::parse,
);

sub parse_payload : prototype($$) {
    my ($channel_name, $payload) = @_;
    my @payload = split /\t/, $payload;

    my $parser = $channels_to_events{$channel_name};
    unless (defined $parser) {
        die "Invalid channel name: '$channel_name'";
    }

    return $parser->(@payload);
}

sub new_event {
    my ($self, $channel_name, $payload) = @_;

    return bless {
        "channel_name" => $channel_name,
        "payload"      => $payload,
        "event"        => parse_payload($channel_name, $payload),
    }, $self;
}

sub interestedIn {
    my ($self, $plugin) = @_;

    return $self->{"event"}->interestedIn($plugin);
}

sub execute {
    my ($self, $db, $plugin) = @_;
    return $self->{"event"}->execute($db, $plugin);
}
