package Hydra::View::Plain;

use strict;
use warnings;
use base 'Catalyst::View::Download::Plain';

sub process {
    my ($self, $c) = @_;
    $c->res->content_encoding("utf-8");
    $self->SUPER::process($c);
}

1;
