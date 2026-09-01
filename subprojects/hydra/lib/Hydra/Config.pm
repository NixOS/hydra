package Hydra::Config;

use strict;
use warnings;
use Config::Any;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
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

# The formats Hydra will read, in the order a bare `hydra.conf`-less
# installation is searched. Which parser runs is decided by the extension, so
# the name of the file is what says how it is written.
our @configExtensions = ("json", "conf");

sub getHydraConfig {
    return $hydraConfigCache if defined $hydraConfigCache;

    if ($ENV{"HYDRA_CONFIG"}) {
        my $conf = $ENV{"HYDRA_CONFIG"};
        $hydraConfigCache = -f $conf ? loadConfig($conf) : {};
        return $hydraConfigCache;
    }

    require Hydra::Model::DB;
    my $dir = Hydra::Model::DB::getHydraPath();

    for my $ext (@configExtensions) {
        my $conf = "$dir/hydra.$ext";
        next unless -f $conf;
        $hydraConfigCache = loadConfig($conf);
        return $hydraConfigCache;
    }

    $hydraConfigCache = {};
    return $hydraConfigCache;
}

# Read one configuration file, in whichever of the supported formats its
# extension names: `.conf` is the Apache-style syntax Hydra has always used,
# `.json` is JSON. The two produce the same structure -- a repeated
# `<runcommand>` block and a JSON array of the same objects are both an
# arrayref here -- so nothing downstream needs to know which was written.
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

# Options, all optional:
#
#   insecure    an arrayref to collect files that hold a secret and are
#               readable by anyone
#   noIncludes  do not read the files an envelope includes, and do not mind
#               that they are not there. For checking a configuration
#               somewhere its `includes' cannot be resolved -- a build
#               sandbox, checking what the NixOS module generated.
#   seen        internal: the files already being read, to catch cycles
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
        my $wrapped = $ext eq "json" && exists $config->{"settings"};

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
    die "$sourceFile: a file with a `settings' block holds only that and"
        . " `includes', but this one also has "
        . join(", ", map { "`$_'" } @unknown) . ".\n"
        if @unknown;

    my $config = $doc->{"settings"} // {};
    my $includes = $doc->{"includes"};
    return $config if $opts->{noIncludes} || !defined $includes;

    my $seen = $opts->{seen} //= { abs_path($sourceFile) => 1 };
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
        die "$sourceFile: `includes' of `$file' is a cycle.\n" if $seen->{$real}++;

        merge($config, loadConfig($real, $opts), "`$sourceFile'", "the included `$file'");
    }

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
