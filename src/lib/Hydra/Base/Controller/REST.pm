package Hydra::Base::Controller::REST;

use strict;
use warnings;
use base 'Catalyst::Controller::REST';

# Hack: Erase the map set by C::C::REST
__PACKAGE__->config(map => undef);
__PACKAGE__->config(
    map => {
        'application/json' => 'JSON',
        'text/x-json'      => 'JSON',
        'text/html'        => [ 'View', 'TT' ]
    },
    default     => 'text/html',
    'stash_key' => 'resource',
);

sub begin { my ($self, $c) = @_; $c->forward('Hydra::Controller::Root::begin'); }
sub end   { my ($self, $c) = @_; $c->forward('Hydra::Controller::Root::end'); }

1;
