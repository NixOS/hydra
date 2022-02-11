use strict;
use warnings;
use Setup;
use Test2::V0;

require Catalyst::Test;
use HTTP::Request::Common qw(POST PUT GET DELETE);
use JSON::MaybeXS qw(decode_json encode_json);
use Hydra::Helper::AddBuilds qw(validateDeclarativeJobset);
use Hydra::Helper::Nix qw(getHydraConfig);

my $ctx = test_context(
    hydra_config => q|
    <dynamicruncommand>
    enable = 1
    </dynamicruncommand>
    |
);

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

subtest "validate declarative jobset with dynamic RunCommand enabled by server" => sub {
    my $config = getHydraConfig();

    subtest "project enabled dynamic runcommand, declarative jobset enabled dynamic runcommand" => sub {
        ok(
            validateDeclarativeJobset(
                $config,
                { enable_dynamic_run_command => 1 },
                "test-jobset",
                makeJobsetSpec(JSON::MaybeXS::true)
            ),
        );
    };

    subtest "project enabled dynamic runcommand, declarative jobset disabled dynamic runcommand" => sub {
        ok(
            validateDeclarativeJobset(
                $config,
                { enable_dynamic_run_command => 1 },
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
                  { enable_dynamic_run_command => 0 },
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
                { enable_dynamic_run_command => 0 },
                "test-jobset",
                makeJobsetSpec(JSON::MaybeXS::false)
            ),
        );
    };
};

done_testing;
