use strict;
use warnings;
use Setup;
use Test2::V0;

require Catalyst::Test;
use HTTP::Request::Common qw(POST PUT GET DELETE);
use JSON::MaybeXS qw(decode_json encode_json);

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project_with_dynamic_run_command = $db->resultset('Projects')->create({
    name => 'tests_with_dynamic_runcommand',
    displayname => 'Tests with dynamic runcommand',
    owner => 'alice',
    enable_dynamic_run_command => 1,
});
my $project_without_dynamic_run_command = $db->resultset('Projects')->create({
    name => 'tests_without_dynamic_runcommand',
    displayname => 'Tests without dynamic runcommand',
    owner => 'alice',
    enable_dynamic_run_command => 0,
});

sub makeJobsetSpec {
    my ($dynamic) = @_;

    return {
        enabled => 2,
        enable_dynamic_run_command => $dynamic ? JSON::MaybeXS::true : undef,
        visible => JSON::MaybeXS::true,
        name => "job",
        type => 1,
        description => "test jobset",
        flake => "github:nixos/nix",
        checkinterval => 0,
        schedulingshares => 100,
        keepnr => 3
    };
};

subtest "validate declarative jobset with dynamic RunCommand disabled by server" => sub {
    my $config = Hydra::Helper::Nix->getHydraConfig();
    require Hydra::Helper::AddBuilds;
    Hydra::Helper::AddBuilds->import( qw(validateDeclarativeJobset) );

    subtest "project enabled dynamic runcommand, declarative jobset enabled dynamic runcommand" => sub {
        like(
            dies {
              validateDeclarativeJobset(
                  $config,
                  $project_with_dynamic_run_command,
                  "test-jobset",
                  makeJobsetSpec(JSON::MaybeXS::true),
              ),
            },
            qr/Dynamic RunCommand is not enabled/,
        );
    };

    subtest "project enabled dynamic runcommand, declarative jobset disabled dynamic runcommand" => sub {
        ok(
            validateDeclarativeJobset(
                $config,
                $project_with_dynamic_run_command,
                "test-jobset",
                makeJobsetSpec(JSON::MaybeXS::false)
            ),
        );
    };

    subtest "project disabled dynamic runcommand, declarative jobset enabled dynamic runcommand" => sub {
        like(
            dies {
              validateDeclarativeJobset(
                  $config,
                  $project_without_dynamic_run_command,
                  "test-jobset",
                  makeJobsetSpec(JSON::MaybeXS::true),
              ),
            },
            qr/Dynamic RunCommand is not enabled/,
        );
    };

    subtest "project disabled dynamic runcommand, declarative jobset disabled dynamic runcommand" => sub {
        ok(
            validateDeclarativeJobset(
                $config,
                $project_without_dynamic_run_command,
                "test-jobset",
                makeJobsetSpec(JSON::MaybeXS::false)
            ),
        );
    };
};

done_testing;
