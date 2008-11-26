package Hydra;

use strict;
use warnings;

use Catalyst::Runtime '5.70';

use parent qw/Catalyst/;
use Catalyst qw/-Debug
                ConfigLoader
                Static::Simple
                StackTrace
                Authentication
                Session
                Session::Store::FastMmap
                Session::State::Cookie
               /;
our $VERSION = '0.01';

__PACKAGE__->config(
    name => 'Hydra',
    default_view => "TT"
    );

__PACKAGE__->setup();

1;
