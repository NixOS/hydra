
use strict;
use warnings;
use Setup;
use Hydra::Config;
use Test2::V0;

my $tmpdir         = File::Temp->newdir();
my $cfgfile        = "$tmpdir/conf";
my $scratchCfgFile = "$tmpdir/hydra.scratch.conf";

my $ldapInHydraConfFile = "$tmpdir/hydra.empty.conf";
write_file($ldapInHydraConfFile, <<CONF);
<ldap>
    <config>
        <credential>
            class = Password
        </credential>
    </config>
    <role_mapping>
        hydra_admin = admin
        hydra_one_group_many_roles = create-projects
        hydra_one_group_many_roles = cancel-build
    </role_mapping>
</ldap>
CONF
my $ldapInHydraConf = Hydra::Config::loadConfig($ldapInHydraConfFile);

my $emptyHydraConfFile = "$tmpdir/hydra.empty.conf";
write_file($emptyHydraConfFile, "");
my $emptyHydraConf = Hydra::Config::loadConfig($emptyHydraConfFile);

my $ldapYamlFile = "$tmpdir/ldap.yaml";
write_file($ldapYamlFile, <<YAML);
credential:
    class: Password
YAML

subtest "getLDAPConfig" => sub {
    subtest "No ldap section and an env var gets us legacy data" => sub {
        like(
            warning {
                is(
                    Hydra::Config::getLDAPConfig($emptyHydraConf, (HYDRA_LDAP_CONFIG => $ldapYamlFile)),
                    {
                        config => {
                            credential => {
                                class => "Password",
                            },
                        },
                        role_mapping => {
                            "hydra_admin"           => ["admin"],
                            "hydra_bump-to-front"   => ["bump-to-front"],
                            "hydra_cancel-build"    => ["cancel-build"],
                            "hydra_create-projects" => ["create-projects"],
                            "hydra_restart-jobs"    => ["restart-jobs"],
                        }
                    },
                    "The empty file and set env var make legacy mode active."
                );
            },
            qr/configured to use LDAP via the HYDRA_LDAP_CONFIG/,
            "Having the environment variable set warns."
        );
    };

    subtest "An ldap section and no env var gets us normalized data" => sub {
        is(
            warns {
                is(
                    Hydra::Config::getLDAPConfig($ldapInHydraConf, ()),
                    {
                        config => {
                            credential => {
                                class => "Password",
                            },
                        },
                        role_mapping => {
                            "hydra_admin"                => ["admin"],
                            "hydra_one_group_many_roles" => [ "create-projects", "cancel-build" ],
                        }
                    },
                    "The empty file and set env var make legacy mode active."
                );
            },
            0,
            "No warnings are issued for non-legacy LDAP support."
        );
    };
};

subtest "is_ldap_in_legacy_mode" => sub {
    subtest "With the environment variable set and an empty hydra.conf" => sub {
        like(
            warning {
                is(Hydra::Config::is_ldap_in_legacy_mode($emptyHydraConf, (HYDRA_LDAP_CONFIG => $ldapYamlFile)),
                    1, "The empty file and set env var make legacy mode active.");
            },
            qr/configured to use LDAP via the HYDRA_LDAP_CONFIG/,
            "Having the environment variable set warns."
        );
    };

    subtest "With the environment variable set and LDAP specified in hydra.conf" => sub {
        like(
            dies {
                Hydra::Config::is_ldap_in_legacy_mode($ldapInHydraConf, (HYDRA_LDAP_CONFIG => $ldapYamlFile));
            },
            qr/HYDRA_LDAP_CONFIG is set, but config is also specified in hydra\.conf/,
            "Having the environment variable set dies to avoid misconfiguration."
        );
    };

    subtest "Without the environment variable set and an empty hydra.conf" => sub {
        is(
            warns {
                is(Hydra::Config::is_ldap_in_legacy_mode($emptyHydraConf, ()),
                    0, "The empty file and unset env var means non-legacy.");
            },
            0,
            "We should receive zero warnings."
        );
    };

    subtest "Without the environment variable set and LDAP specified in hydra.conf" => sub {
        is(
            warns {
                is(Hydra::Config::is_ldap_in_legacy_mode($ldapInHydraConf, ()),
                    0, "The empty file and unset env var means non-legacy.");
            },
            0,
            "We should receive zero warnings."
        );
    };
};

subtest "get_legacy_ldap_config" => sub {
    is(
        Hydra::Config::get_legacy_ldap_config($ldapYamlFile),
        {
            config => {
                credential => {
                    class => "Password",
                },
            },
            role_mapping => {
                "hydra_admin"           => ["admin"],
                "hydra_bump-to-front"   => ["bump-to-front"],
                "hydra_cancel-build"    => ["cancel-build"],
                "hydra_create-projects" => ["create-projects"],
                "hydra_restart-jobs"    => ["restart-jobs"],
            }
        },
        "Legacy, default role maps are applied."
    );
};

subtest "validate_roles" => sub {
    ok(Hydra::Config::validate_roles([]),                           "An empty list is valid");
    ok(Hydra::Config::validate_roles(Hydra::Config::valid_roles()), "All current roles are valid.");
    like(dies { Hydra::Config::validate_roles([""]) }, qr/Invalid roles: ''./, "Invalid roles are failing");
    like(
        dies { Hydra::Config::validate_roles([ "foo", "bar" ]) },
        qr/Invalid roles: 'foo', 'bar'./,
        "All the invalid roles are present in the error"
    );
};

subtest "normalize_ldap_role_mappings" => sub {
    is(Hydra::Config::normalize_ldap_role_mappings({}), {}, "An empty input map is an empty output map.");

    is(
        Hydra::Config::normalize_ldap_role_mappings(
            {
                hydra_admin                => "admin",
                hydra_one_group_many_roles => [ "create-projects", "bump-to-front" ],
            }
        ),
        {
            hydra_admin                => ["admin"],
            hydra_one_group_many_roles => [ "create-projects", "bump-to-front" ],
        },
        "Lists and plain strings normalize to lists"
    );

    like(
        dies {
            Hydra::Config::normalize_ldap_role_mappings(
                {
                    "group" => "invalid-role",
                }
              ),
        },
        qr/Failed to normalize.*Invalid roles.*invalid-role/s,
        "Invalid roles fail to normalize."
    );

    like(
        dies {
            Hydra::Config::normalize_ldap_role_mappings(
                {
                    "group" => { "nested" => "data" },
                }
              ),
        },
        qr/On group 'group':.* Only strings/,
        "Invalid nesting fail to normalize."
    );
};

done_testing;
