package Hydra::View::Plain;

use strict;
use warnings;
use base 'Catalyst::View::Download::Plain';

sub process {
    my ($self, $c) = @_;
    $c->clear_encoding;
    $c->response->content_type('text/plain; charset=utf-8') if $c->response->content_type() eq "text/plain";
    $c->response->body($c->stash->{plain}->{data});
}

1;
