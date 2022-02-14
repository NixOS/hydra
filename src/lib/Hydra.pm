package Hydra;

use strict;
use warnings;
use parent 'Catalyst';
use Moose;
use Hydra::Plugin;
use Hydra::Model::DB;
use Hydra::Config qw(getLDAPConfigAmbient);
use Catalyst::Runtime '5.70';
use Catalyst qw/ConfigLoader
                Static::Simple
                StackTrace
                Authentication
                Authorization::Roles
                Session
                Session::Store::FastMmap
                Session::State::Cookie
                Captcha
                PrometheusTiny/,
                '-Log=warn,fatal,error';
use CatalystX::RoleApplicator;
use Path::Class 'file';

our $VERSION = '0.01';

__PACKAGE__->config(
    name => 'Hydra',
    default_view => "TT",
    'Plugin::Authentication' => {
        default_realm => "dbic",

        dbic => {
            credential => {
                class => "Password",
                password_field => "password",
                password_type => "self_check",
            },
            store => {
                class => "DBIx::Class",
                user_class => "DB::Users",
                role_relation => "userroles",
                role_field => "role",
            },
        },
        ldap => getLDAPConfigAmbient()->{'config'}
    },
    'Plugin::ConfigLoader' => {
        driver => {
            'General' => \%Hydra::Config::configGeneralOpts
        }
    },
    'Plugin::PrometheusTiny' => {
        include_action_labels => 1,
    },
    'Plugin::Static::Simple' => {
        send_etag => 1,
        expires => 3600
    },
    'View::JSON' => {
        expose_stash => 'json'
    },
    'Plugin::Session' => {
        expires => 3600 * 24 * 7,
        storage => Hydra::Model::DB::getHydraPath . "/www/session_data",
        unlink_on_exit => 0
    },
    'Plugin::Captcha' => {
        session_name => 'hydra-captcha',
        new => {
            width => 270,
            height => 80,
            ptsize => 20,
            lines => 30,
            thickness => 1,
            rndmax => 5,
            scramble => 1,
            #send_ctobg => 1,
            bgcolor => '#ffffff',
            font => __PACKAGE__->path_to("ttf/StayPuft.ttf"),
        },
        create => [ qw/ttf circle/ ],
        particle => [ 3500 ],
        out => { force => 'jpeg' }
    },
);

__PACKAGE__->apply_request_class_roles(qw/Catalyst::TraitFor::Request::ProxyBase/);

my $plugins;

has 'hydra_plugins' => (
    is => 'ro',
    default => sub { return $plugins; }
);

after setup_finalize => sub {
    my $class = shift;
    $plugins = [Hydra::Plugin->instantiate(db => $class->model('DB'), config => $class->config)];
};

__PACKAGE__->setup();

1;
