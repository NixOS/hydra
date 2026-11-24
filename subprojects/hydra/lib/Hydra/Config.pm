package Hydra::Config;

use strict;
use warnings;
use feature qw(signatures);
use Config::Any;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use List::SomeUtils qw(none);
use URI::Escape qw(uri_escape);
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

our @EXPORT_OK = qw(
    normalize_oidc_role_mappings
    oidc_roles_from_claim
    signinMethods
    localAuthEnabled
    passwordSigninEnabled
);

my $hydraConfigCache;

# Settings that used to live in `hydra.conf` and now belong to a component's
# own configuration file. Left here they are silently inert, which looks
# exactly like the setting having no effect; `hydra-config` says so.
our %movedSettings = map { $_ => "`$_` in /etc/hydra/evaluator.toml" } qw(
    max_concurrent_evals
    evaluator_workers
    evaluator_max_memory_size
    allow_import_from_derivation
    eval_substituter
);

# Everything about a configuration that is allowed but probably not meant.
#
# Only `hydra-config` reports these. That is where people check their
# configuration, and the services, which read it in every process, would
# otherwise repeat them in every log.
sub configWarnings {
    my ($config) = @_;
    my @warnings;

    for my $key (sort keys %movedSettings) {
        next unless exists $config->{$key};
        push @warnings, "`$key' is no longer read from Hydra's configuration."
            . " Set $movedSettings{$key} instead.";
    }

    push @warnings, "`email_notification' is deprecated: use the"
        . " `email_notifications' block instead, which says which kinds of mail"
        . " you want rather than enabling all of them."
        if defined $config->{email_notification};

    push @warnings, "`local_auth_enabled = 0', and no LDAP server, GitHub"
        . " application or OIDC provider is configured, so there is no way to"
        . " sign in. A private Hydra will be unreachable."
        unless @{signinMethods($config, "")};

    return @warnings;
}

# The formats Hydra will read, in the order a bare `hydra.conf`-less
# installation is searched. Which parser runs is decided by the extension, so
# the name of the file is what says how it is written.
our @configExtensions = ("json", "conf");

sub getHydraConfig {
    return $hydraConfigCache if defined $hydraConfigCache;

    my $conf = findHydraConfig();
    $hydraConfigCache = defined $conf ? loadConfig($conf) : {};
    return $hydraConfigCache;
}

# The file to read, or `undef` if there is none.
sub findHydraConfig {
    if ($ENV{"HYDRA_CONFIG"}) {
        my $conf = $ENV{"HYDRA_CONFIG"};
        return -f $conf ? $conf : undef;
    }

    require Hydra::Model::DB;
    my $dir = Hydra::Model::DB::getHydraPath();

    for my $ext (@configExtensions) {
        my $conf = "$dir/hydra.$ext";
        return $conf if -f $conf;
    }

    return undef;
}

# The settings that hold a secret.
#
# A file containing any of these must not be readable by anyone but Hydra, and
# in particular must not be the file the NixOS module generates -- everything
# in the Nix store is world-readable, which is what `includes` exists to work
# around. `hydra-config` checks this, since the mistake is invisible until
# someone reads the token out of your store.
#
# Paths are dotted. A repeated block is a list here and a single one is not, so
# list nesting is not a step in the path: `githubstatus.authorization` finds it
# whether there is one `<githubstatus>` block or several.
our @secretSettings = (
    "bitbucket.password",
    "bitbucket_authorization",
    "circleci.token",
    "coverityscan.token",
    "gitea_authorization",
    "github_authorization",
    "githubstatus.authorization",
    "gitlab_authorization",
    "ldap.config.store.bindpw",
    "slack.url",
    "webhooks",
);

# Which of the secret-bearing settings a configuration contains.
sub secretsIn {
    my ($config) = @_;
    return grep { hasSetting($config, split /\./, $_) } @secretSettings;
}

sub hasSetting {
    my ($node, @path) = @_;

    return 0 unless defined $node;
    return 1 unless @path;

    if (ref $node eq "ARRAY") {
        for my $element (@$node) {
            return 1 if hasSetting($element, @path);
        }
        return 0;
    }

    return 0 unless ref $node eq "HASH";
    my $key = shift @path;
    return exists $node->{$key} && hasSetting($node->{$key}, @path);
}

# Whether anyone at all can read this file.
sub isWorldReadable {
    my ($file) = @_;
    my @stat = stat($file) or return 0;
    return ($stat[2] & 0004) != 0;
}

# Read one configuration file, in whichever of the supported formats its
# extension names: `.conf` is the Apache-style syntax Hydra has always used,
# `.json` is JSON. The two produce the same structure -- a repeated
# `<runcommand>` block and a JSON array of the same objects are both an
# arrayref here -- so nothing downstream needs to know which was written.
#
# Options, all optional:
#
#   insecure    an arrayref to collect files that hold a secret and are
#               readable by anyone
#   noIncludes  do not read the files an envelope includes, and do not mind
#               that they are not there. For checking a configuration
#               somewhere its `includes' cannot be resolved -- a build
#               sandbox, checking what the NixOS module generated.
#   seen        internal: the files currently being read, to catch cycles
sub loadConfig {
    my ($sourceFile, $opts) = @_;
    $opts //= {};

    # Config::Any would also read INI, XML, YAML and Perl, going by the
    # extension. Only the two Hydra documents are accepted, so that the set of
    # ways to write a configuration is the set anyone has thought about.
    my ($ext) = $sourceFile =~ /\.([^.\/]+)$/;
    $ext = lc($ext // "");
    unless (grep { $_ eq $ext } @configExtensions) {
        die "$sourceFile: no parser for this file. Hydra reads "
            . join(" and ", map { "`.$_'" } @configExtensions) . ".\n";
    }

    my $loaded = Config::Any->load_files({
        files => [$sourceFile],
        use_ext => 1,
        driver_args => { General => \%configGeneralOpts },
    });

    for my $parsed (@$loaded) {
        my ($doc, $config) = %$parsed;
        next unless $doc eq $sourceFile;

        # Only in JSON. The Apache-style syntax has `Include` already, and
        # giving `settings` and `includes` a meaning there would change what
        # existing files mean -- a `<settings>` block someone already has would
        # stop being a setting called `settings`.
        my $wrapped = $ext eq "json"
            && (exists $config->{"settings"} || exists $config->{"includes"});

        # What this file itself says, before anything it includes is folded in,
        # so that a secret is reported against the file it is actually in.
        if (defined $opts->{insecure} && isWorldReadable($sourceFile)) {
            my $own = $wrapped ? ($config->{"settings"} // {}) : $config;
            my @secrets = secretsIn($own);
            push @{$opts->{insecure}}, { file => $sourceFile, settings => \@secrets }
                if @secrets;
        }

        return $wrapped ? unwrap($config, $sourceFile, $opts) : $config;
    }

    die "$sourceFile: could not be read as "
        . join(" or ", map { "`.$_'" } @configExtensions) . ".\n";
}

# Take the settings out of a parsed configuration file, reading whatever it
# asks to include.
#
# A JSON file is either settings alone, as Hydra has always taken it, or an
# envelope around them:
#
#     { "includes": [ "/run/keys/hydra/secrets.json" ],
#       "settings": { "max_servers": 25 } }
#
# The envelope exists because a generated configuration needs somewhere to name
# files it does not contain -- that is how secrets stay out of the Nix store now
# that the NixOS module writes JSON, which has no include mechanism of its own.
# JSON only. The Apache-style syntax has `Include`, and reading `settings` and
# `includes` there would change the meaning of files that already use those
# names for settings. An included file may be in either format; it is settings,
# and is not unwrapped again unless it is JSON.
sub unwrap {
    my ($doc, $sourceFile, $opts) = @_;

    my @unknown = grep { $_ ne "includes" && $_ ne "settings" } sort keys %$doc;
    die "$sourceFile: a file with `settings' or `includes' holds only those,"
        . " but this one also has "
        . join(", ", map { "`$_'" } @unknown) . ".\n"
        if @unknown;

    my $config = $doc->{"settings"} // {};
    my $includes = $doc->{"includes"};
    return $config if $opts->{noIncludes} || !defined $includes;

    # Only the files on the way down to this one: the same file included
    # twice from different places is not a cycle.
    my $seen = $opts->{seen} //= {};
    my $self = abs_path($sourceFile);
    $seen->{$self} = 1;
    my $dir = dirname($sourceFile);

    for my $file (ref $includes eq "ARRAY" ? @$includes : ($includes)) {
        # Relative to the file doing the including, as `-IncludeRelative` is
        # for the Apache-style syntax.
        my $path = $file =~ m{^/} ? $file : "$dir/$file";

        my $real = abs_path($path);
        die "$sourceFile: `includes' names `$file', which does not exist.\n"
            unless defined $real && -f $real;

        # An include reaching a file already being read would otherwise recurse
        # until perl runs out of stack.
        die "$sourceFile: `includes' of `$file' is a cycle.\n" if $seen->{$real};

        merge($config, loadConfig($real, $opts), "`$sourceFile'", "the included `$file'");
    }

    delete $seen->{$self};

    return $config;
}

# Fold one configuration into another.
#
# Blocks combine, so a file holding only the secret parts of a block adds to
# what the other file says about it rather than replacing it, and repeated
# blocks -- `<runcommand>` and the rest, which are lists here -- append.
#
# Anything else set in both places is an error. The two files disagree about a
# single value and which was meant is not for Hydra to guess, the same reason
# `email_notification` refuses to coexist with the block that replaced it.
sub merge {
    my ($into, $from, $intoName, $fromName, @path) = @_;

    for my $key (sort keys %$from) {
        my @here = (@path, $key);
        my ($mine, $theirs) = ($into->{$key}, $from->{$key});

        if (!exists $into->{$key}) {
            $into->{$key} = $theirs;
        } elsif (ref $mine eq "HASH" && ref $theirs eq "HASH") {
            merge($mine, $theirs, $intoName, $fromName, @here);
        } elsif (ref $mine eq "ARRAY" && ref $theirs eq "ARRAY") {
            push @$mine, @$theirs;
        } else {
            die "`" . join(".", @here) . "' is set in both $intoName and"
                . " $fromName. Set it in one of them.\n";
        }
    }
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

sub signinMethods($config, $path) {
    my @methods;

    if ($config->{github_client_id}) {
        push @methods, {
            label => "Sign in with GitHub",
            href => externalSigninHref("/github-redirect", $path),
        };
    }

    my $providers = ($config->{oidc} // {})->{provider} // {};
    for my $name (sort keys %$providers) {
        push @methods, {
            label => "Sign in with " . ($providers->{$name}->{display_name} // "OIDC ($name)"),
            href => externalSigninHref("/oidc-redirect/" . uri_escape($name), $path),
        };
    }

    if (passwordSigninEnabled($config)) {
        push @methods, {
            label => localAuthEnabled($config) ? "Sign in with a Hydra account" : "Sign in with LDAP",
            href => "#hydra-signin",
            form => 1,
        };
    }

    return \@methods;
}

# Whether Hydra's own accounts can sign in with a password.
sub localAuthEnabled($config) {
    return ($config->{local_auth_enabled} // "1") ne "0";
}

# Whether the password form is offered at all: for Hydra accounts, LDAP, or both.
sub passwordSigninEnabled($config) {
    return localAuthEnabled($config)
        || defined $config->{ldap}
        || defined $ENV{"HYDRA_LDAP_CONFIG"};
}

sub externalSigninHref($path_to, $path) {
    return $path_to . "?after=" . uri_escape($path // "");
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

# An OIDC provider's role_mapping translates the values the IDP puts in its
# role claim into Hydra roles. The IDP's idea of a role or group need not be
# spelled the way Hydra spells its roles, so the mapping is keyed by whatever
# the IDP sends instead.
sub normalize_oidc_role_mappings {
    my ($input_map) = @_;

    return undef unless defined $input_map;

    my $mapping = {};

    my @errors;

    for my $claim_value (keys %{$input_map}) {
        my $input = $input_map->{$claim_value};

        if (ref $input eq "ARRAY") {
            $mapping->{$claim_value} = $input;
        } elsif (ref $input eq "") {
            $mapping->{$claim_value} = [ $input ];
        } else {
            push @errors, "On claim value '$claim_value': the value is of type ${\ref $input}. Only strings and lists are acceptable.";
            $mapping->{$claim_value} = [ ];
        }

        eval {
            validate_roles($mapping->{$claim_value});
        };
        if ($@) {
            push @errors, "On claim value '$claim_value': $@";
        }
    }

    if (@errors) {
        die "Failed to normalize OIDC role mappings:\n" . (join "\n", @errors);
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

# Some OIDC identity provider implementations (e.g. kanidm) have restrictions on what values can
# be put in custom claims. We look for the roles to add users to based on the hydra_roles claim,
# and e.g. kanidm does not allow dashes in this claim. So accept underscores in place of dashes
# in the role names.
sub normalize_role_name {
    my ($role) = @_;
    return $role =~ s/_/-/gr;
}

# The claim we look for roles in if a provider doesn't configure `role_claim`.
our $default_oidc_role_claim = "hydra_roles";

# Work out which Hydra roles a set of ID token claims grants. Returns undef if
# the IDP presented no role claim at all, so the caller can tell "no roles"
# apart from "nothing said about roles".
sub oidc_roles_from_claim ($conf, $claims) {
    my $claim_name = $conf->{role_claim} // $default_oidc_role_claim;
    my $value = $claims->{$claim_name};

    return undef unless defined $value;

    my @values = ref $value eq "ARRAY" ? @{$value} : ($value);
    my $mapping = $conf->{role_mapping};

    if ($mapping && keys %$mapping) {
        # IDP-provided values are only as trustworthy as the rest of the
        # token, so grant the mapped roles and nothing else. resolveOIDCConfig
        # has already rejected a mapping with a role Hydra does not know
        # about, but check again here since nothing stops a caller from
        # passing in a config that never went through it.
        my %is_valid_role = map { $_ => 1 } @{valid_roles()};
        my @mapped;
        for my $value (@values) {
            my $roles = $mapping->{$value};
            next unless defined $roles;
            push @mapped, ref $roles eq "ARRAY" ? @{$roles} : ($roles);
        }
        my %seen;
        return [ grep { !$seen{$_}++ && $is_valid_role{$_} } @mapped ];
    }

    # Without a mapping the claim is expected to name Hydra roles directly.
    # Some OIDC identity provider implementations (e.g. kanidm) have
    # restrictions on what values can be put in custom claims, and cannot put
    # dashes in them, so accept underscores in place of dashes.
    my %is_valid_role = map { $_ => 1 } @{valid_roles()};
    return [ grep { $is_valid_role{$_} } map { normalize_role_name($_) } @values ];
}

1;
