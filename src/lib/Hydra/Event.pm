package Hydra::Event;


use strict;
use Hydra::Event::BuildFinished;
use Hydra::Event::BuildStarted;
use Hydra::Event::StepFinished;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    parse_payload
);

my %channels_to_events = (
  build_started => \&Hydra::Event::BuildStarted::parse,
  step_finished => \&Hydra::Event::StepFinished::parse,
  build_finished => \&Hydra::Event::BuildFinished::parse,
);


sub parse_payload :prototype($$) {
    my ($channel_name, $payload) = @_;
    my @payload = split /\t/, $payload;

    my $parser = %channels_to_events{$channel_name};
    unless (defined $parser) {
      die "Invalid channel name: '$channel_name'";
    }

    return $parser->(@payload);
}
