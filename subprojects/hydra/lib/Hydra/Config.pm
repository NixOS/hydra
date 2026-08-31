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
    buildEmailNotificationEnabled
    evalEmailNotificationEnabled
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

# Hydra sends two unrelated kinds of mail, and `email_notification` used to
# turn on both at once. They are separate switches now, because wanting one
# rarely means wanting the other: build results go to whoever maintains the
# job, while evaluation errors go to the project's owner alone.
#
#     <email_notifications>
#       build = 1
#       eval = 1
#     </email_notifications>
#
# The old key still works and still means both, so an existing `hydra.conf`
# keeps behaving as it did. It is spelled without the s, which is what lets the
# block take the plural name: `Config::General` cannot have a scalar and a
# block of the same name.
my $warnedEmailNotification;

sub emailNotificationEnabled {
    my ($config, $key) = @_;

    my $legacy = $config->{"email_notification"};
    my $block = $config->{"email_notifications"};

    if (defined $block && ref $block ne "HASH") {
        die "hydra.conf: `email_notifications' is a block:\n\n"
            . "  <email_notifications>\n"
            . "    build = 1\n"
            . "    eval = 1\n"
            . "  </email_notifications>\n\n"
            . "You may have meant the deprecated `email_notification', without the s.\n";
    }

    # Refusing both rather than picking a winner: the two say the same thing in
    # different words, and a `hydra.conf` that sets both is one whose author
    # believes something about the result. Same reason the legacy LDAP
    # configuration refuses to coexist with the current one.
    if (defined $legacy && defined $block) {
        die "hydra.conf sets both `email_notification' and the `email_notifications'\n"
            . "block. The former is deprecated and means both kinds; drop it and say\n"
            . "what you want in the block.\n";
    }

    if (defined $legacy && !$warnedEmailNotification) {
        $warnedEmailNotification = 1;
        warn "hydra.conf sets `email_notification', which is deprecated: use the "
            . "`email_notifications' block instead, which says which kinds of mail "
            . "you want rather than enabling all of them.\n";
    }

    # Compared as a string: these come out of `hydra.conf` as text, and an empty
    # value is a perfectly ordinary way to write "off" without warning about it
    # not being a number.
    my $value = defined $block ? $block->{$key} : $legacy;
    return defined $value && $value eq "1";
}

# Whether to mail about finished builds.
sub buildEmailNotificationEnabled {
    my ($config) = @_;
    return emailNotificationEnabled($config, "build");
}

# Whether to mail a project's owner about its jobsets' evaluation errors.
sub evalEmailNotificationEnabled {
    my ($config) = @_;
    return emailNotificationEnabled($config, "eval");
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
            "hydra_eval-jobset" => [ "eval-jobset" ],
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
        die "Failed to normalize LDAP role mappings:\n" . (join "\n", @errors);
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
        "eval-jobset",
        "restart-jobs",
    ];
}

1;
