package Hydra::Base::Controller::REST;

use strict;
use warnings;
use base 'Catalyst::Controller::REST';

__PACKAGE__->config(
    map => {
        'text/html' => [ 'View', 'TT' ]
    },
    default => 'text/html',
    'stash_key' => 'resource',
);

sub begin { my ( $self, $c ) = @_; $c->forward('Hydra::Controller::Root::begin'); }
sub end { my ( $self, $c ) = @_; $c->forward('Hydra::Controller::Root::end'); }

1;
