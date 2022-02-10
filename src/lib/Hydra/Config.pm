package Hydra::Config;

use strict;
use warnings;
use Config::General;
use List::SomeUtils qw(none);
use YAML qw(LoadFile);

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getHydraConfig
    getLDAPConfig
    getLDAPConfigAmbient
);

our %configGeneralOpts = (-UseApacheInclude => 1, -IncludeAgain => 1, -IncludeRelative => 1);

my $hydraConfigCache;

sub getHydraConfig {
    return $hydraConfigCache if defined $hydraConfigCache;

    my $conf;

    if ($ENV{"HYDRA_CONFIG"}) {
        $conf = $ENV{"HYDRA_CONFIG"};
    } else {
        require Hydra::Model::DB;
        $conf = Hydra::Model::DB::getHydraPath() . "/hydra.conf"
    };

    if (-f $conf) {
        $hydraConfigCache = loadConfig($conf);
    } else {
        $hydraConfigCache = {};
    }

    return $hydraConfigCache;
}

sub loadConfig {
    my ($sourceFile) = @_;

    my %opts = (%configGeneralOpts, -ConfigFile => $sourceFile);

    return { Config::General->new(%opts)->getall };
}

sub is_ldap_in_legacy_mode {
    my ($config, %env) = @_;

    my $legacy_defined = defined $env{"HYDRA_LDAP_CONFIG"};

    if (defined $config->{"ldap"}) {
        if ($legacy_defined) {
            die "The legacy environment variable HYDRA_LDAP_CONFIG is set, but config is also specified in hydra.conf. Please unset the environment variable.";
        }

        return 0;
    } elsif ($legacy_defined) {
        warn "Hydra is configured to use LDAP via the HYDRA_LDAP_CONFIG, a deprecated method. Please see the docs about configuring LDAP in the hydra.conf.";
        return 1;
    } else {
        return 0;
    }
}

sub getLDAPConfigAmbient {
    return getLDAPConfig(getHydraConfig(), %ENV);
}

sub getLDAPConfig {
    my ($config, %env) = @_;

    my $ldap_config;

    if (is_ldap_in_legacy_mode($config, %env)) {
        $ldap_config = get_legacy_ldap_config($env{"HYDRA_LDAP_CONFIG"});
    } else {
        $ldap_config = $config->{"ldap"};
    }

    $ldap_config->{"role_mapping"} = normalize_ldap_role_mappings($ldap_config->{"role_mapping"});

    return $ldap_config;
}

sub get_legacy_ldap_config {
    my ($ldap_yaml_file) = @_;

    return {
        config => LoadFile($ldap_yaml_file),
        role_mapping => {
            "hydra_admin" => [ "admin" ],
            "hydra_bump-to-front" => [ "bump-to-front" ],
            "hydra_cancel-build" => [ "cancel-build" ],
            "hydra_create-projects" => [ "create-projects" ],
            "hydra_restart-jobs" => [ "restart-jobs" ],
        },
    };
}

sub normalize_ldap_role_mappings {
    my ($input_map) = @_;

    my $mapping = {};

    my @errors;

    for my $group (keys %{$input_map}) {
        my $input = $input_map->{$group};

        if (ref $input eq "ARRAY") {
            $mapping->{$group} = $input;
        } elsif (ref $input eq "") {
            $mapping->{$group} = [ $input ];
        } else {
            push @errors, "On group '$group': the value is of type ${\ref $input}. Only strings and lists are acceptable.";
            $mapping->{$group} = [ ];
        }

        eval {
            validate_roles($mapping->{$group});
        };
        if ($@) {
            push @errors, "On group '$group': $@";
        }
    }

    if (@errors) {
        die join "\n", @errors;
    }

    return $mapping;
}

sub validate_roles {
    my ($roles) = @_;

    my @invalid;
    my $valid = valid_roles();

    for my $role (@$roles) {
        if (none { $_ eq $role } @$valid) {
            push @invalid, "'$role'";
        }
    }

    if (@invalid) {
        die "Invalid roles: ${\join ', ', @invalid}. Valid roles are: ${\join ', ', @$valid}.";
    }

    return 1;
}

sub valid_roles {
    return [
        "admin",
        "bump-to-front",
        "cancel-build",
        "create-projects",
        "restart-jobs",
    ];
}

1;
