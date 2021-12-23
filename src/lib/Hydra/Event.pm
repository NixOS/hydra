package Hydra::Event;

use strict;
use warnings;
use Hydra::Event::BuildFinished;
use Hydra::Event::BuildQueued;
use Hydra::Event::BuildStarted;
use Hydra::Event::StepFinished;

my %channels_to_events = (
  build_queued => \&Hydra::Event::BuildQueued::parse,
  build_started => \&Hydra::Event::BuildStarted::parse,
  step_finished => \&Hydra::Event::StepFinished::parse,
  build_finished => \&Hydra::Event::BuildFinished::parse,
);


sub parse_payload :prototype($$) {
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
        "payload" => $payload,
        "event" => parse_payload($channel_name, $payload),
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
