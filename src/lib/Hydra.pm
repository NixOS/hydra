package Hydra;

use strict;
use warnings;
use Hydra::Model::DB;

use Catalyst::Runtime '5.70';

use parent qw/Catalyst/;
use Catalyst qw/ConfigLoader
                Static::Simple
                StackTrace
                Authentication
                Authorization::Roles
                Session
                Session::Store::FastMmap
                Session::State::Cookie
                AccessLog
                -Log=warn,fatal,error
               /;
our $VERSION = '0.01';

__PACKAGE__->config(
    name => 'Hydra',
    default_view => "TT",
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
    },
    'View::JSON' => {
        expose_stash => qr/^json/,
    },
    'Plugin::Session' => {
        expires => 3600 * 24 * 2,
        storage => Hydra::Model::DB::getHydraPath . "/session_data"
    },
    'Plugin::AccessLog' => {
        formatter => {
            format => '%h %l %u %t "%r" %s %b "%{Referer}i" "%{User-Agent}i" %[handle_time]',
        },
    },
);

__PACKAGE__->setup();

1;
