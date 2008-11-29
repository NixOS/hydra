package Hydra;

use strict;
use warnings;
use Hydra::Helper::Nix;

use Catalyst::Runtime '5.70';

use parent qw/Catalyst/;
use Catalyst qw/-Debug
                ConfigLoader
                Static::Simple
                StackTrace
                Authentication
                Authorization::Roles
                Session
                Session::Store::FastMmap
                Session::State::Cookie
               /;
our $VERSION = '0.01';

__PACKAGE__->config(
    name => 'Hydra',
    default_view => "TT",
    session => {
        storage => getHydraPath . "/session_data"
    },
    authentication => {
        default_realm => "dbic",
        realms => {
            dbic => {
                credential => {
                    class => "Password",
                    password_field => "password",
                    password_type => "hashed",
                    password_hash_type => "SHA-1",
                },
                store => {
                    class => "DBIx::Class",
                    user_class => "DB::Users",
                    role_relation => "userroles",
                    role_field => "role",
                },
            },
        },
    }
);

__PACKAGE__->setup();

1;
