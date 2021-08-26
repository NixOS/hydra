package Hydra::Task;

use strict;
use warnings;

sub new {
    my ($self, $event, $plugin_name) = @_;

    return bless {
        "event" => $event,
        "plugin_name" => $plugin_name,
    }, $self;
}

1;
