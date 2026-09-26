package HydraTest::Config::OIDC;

use warnings;
use strict;

use Test2::V0;
use Test2::Tools::Exception qw(lives);
use Hydra::Config;
use Hydra::Helper::OIDC;

subtest "normalize_oidc_role_mappings" => sub {
    is(Hydra::Config::normalize_oidc_role_mappings(undef), undef,
        "No mapping is no mapping");

    is(Hydra::Config::normalize_oidc_role_mappings({}),
        {},
        "An empty mapping stays empty");

    is(Hydra::Config::normalize_oidc_role_mappings({
            powerusers => "admin",
            builders => "restart-jobs",
        }),
        {
            powerusers => ["admin"],
            builders => ["restart-jobs"],
        },
        "A single role is turned into a list of one");

    is(Hydra::Config::normalize_oidc_role_mappings({
            builders => ["restart-jobs", "cancel-build"],
        }),
        {
            builders => ["restart-jobs", "cancel-build"],
        },
        "A list of roles is left alone");

    like(dies { Hydra::Config::normalize_oidc_role_mappings({ powerusers => "superuser" }) },
        qr/On claim value 'powerusers': Invalid roles: 'superuser'\./,
        "Roles Hydra does not know about are rejected");

    like(dies { Hydra::Config::normalize_oidc_role_mappings({ powerusers => ["admin", "wat"] }) },
        qr/Invalid roles: 'wat'\./,
        "One bad role in a list rejects the list");

    like(dies { Hydra::Config::normalize_oidc_role_mappings({ powerusers => { deep => "admin" } }) },
        qr/On claim value 'powerusers': the value is of type HASH\. Only strings and lists are acceptable\./,
        "Values that are neither a string nor a list are rejected");
};

subtest "role mapping is validated when the OIDC config is resolved" => sub {
    my $provider = {
        client_id => "hydra",
        client_secret => "secret",
        discovery_url => "https://idp.example.com/.well-known/openid-configuration",
        role_mapping => { powerusers => ["admin", "cancel-build"] },
    };

    ok(lives { Hydra::Helper::OIDC::resolveOIDCConfig({ provider => { mapped => { %$provider } } }) },
        "A valid mapping is accepted");
    is($provider->{role_mapping}->{powerusers}, ["admin", "cancel-build"],
        "A valid mapping is normalized in place");

    my $bad_provider = { %$provider, role_mapping => { powerusers => ["nonsense"] } };
    like(dies { Hydra::Helper::OIDC::resolveOIDCConfig({ provider => { mapped => $bad_provider } }) },
        qr/Invalid roles: 'nonsense'/,
        "A typo in the role mapping is caught at startup");
};

subtest "roles are taken from the hydra_roles claim by default" => sub {
    is(Hydra::Config::oidc_roles_from_claim({}, { hydra_roles => ["admin", "restart_jobs"] }),
        ["admin", "restart-jobs"],
        "Roles in the default claim are used, with underscores allowed for dashes");

    is(Hydra::Config::oidc_roles_from_claim({}, { hydra_roles => ["admin", "super_user"] }),
        ["admin"],
        "Roles Hydra does not know about are dropped");

    is(Hydra::Config::oidc_roles_from_claim({}, { hydra_roles => "admin" }),
        ["admin"],
        "A single role that is not in a list is still a role");

    is(Hydra::Config::oidc_roles_from_claim({}, {}), undef,
        "No claim at all means the IDP said nothing about roles");

    is(Hydra::Config::oidc_roles_from_claim({}, { hydra_roles => [] }), [],
        "An empty claim means no roles");
};

subtest "the claim the roles come from is configurable" => sub {
    my $conf = { role_claim => "idp_roles" };

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["admin"] }),
        ["admin"],
        "Roles are read from the configured claim");

    is(Hydra::Config::oidc_roles_from_claim($conf, { hydra_roles => ["admin"] }),
        undef,
        "The default claim is not read when another one is configured");

    is(Hydra::Config::oidc_roles_from_claim($conf, {}), undef,
        "Still nothing said about roles without the configured claim");
};

subtest "role_mapping maps what the IDP says to Hydra's roles" => sub {
    my $conf = {
        role_claim => "idp_roles",
        role_mapping => {
            powerusers => ["admin"],
            builders => ["restart-jobs", "cancel-build"],
        },
    };

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["powerusers"] }),
        ["admin"],
        "One IDP value can mean one Hydra role");

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["builders"] }),
        ["restart-jobs", "cancel-build"],
        "One IDP value can mean several Hydra roles");

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["powerusers", "builders"] }),
        ["admin", "restart-jobs", "cancel-build"],
        "Several IDP values can mean several Hydra roles");

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["powerusers", "powerusers"] }),
        ["admin"],
        "A role the IDP repeats is only set once");

    is(Hydra::Config::oidc_roles_from_claim($conf, { idp_roles => ["powerusers", "ghosts"] }),
        ["admin"],
        "IDP values that the mapping does not mention grant nothing");

    # A mapped IDP value is not a Hydra role name, so the fallback of trusting
    # the claim must not kick in.
    is(Hydra::Config::oidc_roles_from_claim({ role_claim => "idp_roles", role_mapping => $conf->{role_mapping} },
        { idp_roles => ["admin"] }),
        [],
        "Without a mapping entry, a Hydra role name in the claim grants nothing");

    is(Hydra::Config::oidc_roles_from_claim({ role_mapping => {} },
        { hydra_roles => ["admin"] }),
        ["admin"],
        "An empty mapping falls back to treating the claim as Hydra roles");

    # Config that never went through normalize_oidc_role_mappings still has to
    # work, since the mapping is only normalized at startup.
    is(Hydra::Config::oidc_roles_from_claim({ role_mapping => { restart_jobs => "admin" } },
        { hydra_roles => ["restart_jobs"] }),
        ["admin"],
        "A mapping whose values are still plain strings works");

    is(Hydra::Config::oidc_roles_from_claim({ role_mapping => { powerusers => ["admin", "wat"] } },
        { hydra_roles => ["powerusers"] }),
        ["admin"],
        "Roles a mapping does not validly spell are dropped");
};

done_testing;
