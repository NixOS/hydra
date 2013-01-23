package Hydra::View::Plain;

use strict;
use warnings;
use base 'Catalyst::View::Download::Plain';

sub process {
    my ($self, $c) = @_;
    $c->response->content_encoding("utf-8");
    $c->response->content_type('text/plain') unless $c->response->content_type() ne "";
    $self->SUPER::process($c);
}

1;
