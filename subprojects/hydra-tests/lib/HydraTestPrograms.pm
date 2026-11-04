use warnings;
use strict;

package HydraTestPrograms;

# Gives each Hydra program the tests launch what its wrapper or NixOS unit
# would give it, and nothing else.
#
# Hydra finds every program it runs through its own `HYDRA_PROGRAM_*`
# variable, and has no `PATH` (see `Hydra::Helper::Exec`). So that a program
# missing one fails here as it would when deployed, a program under test does
# not inherit the test's: `withProgramEnv` takes them away, `PATH` and
# `HYDRA_PLUGIN_PATH` too, and sets just that program's, from the map in
# `HYDRA_TEST_PROGRAM_ENV`, which the dev shell or the packaged test suite
# builds from `packaging/programs.nix`.
#
# The test process itself is different: it runs the web app and plugin code
# in-process, so it gets what any of Hydra's Perl would, from the map's own
# entry for it, and keeps its own `PATH` for the tools the tests use.

use File::Basename;
use File::Temp qw(tempdir);
use JSON::MaybeXS;

our @ISA = qw(Exporter);
our @EXPORT = qw(withProgramEnv);

# Where the launchers for the unwrapped scripts are, if they are run that way.
my $launcherDir;

sub isProgramVar {
    my ($name) = @_;
    return $name =~ /^HYDRA_PROGRAM_/ || $name eq 'HYDRA_PLUGIN_PATH';
}

my $programEnv = do {
    my $file = $ENV{HYDRA_TEST_PROGRAM_ENV}
        or die "HYDRA_TEST_PROGRAM_ENV is not set: it must name what each program is given\n";
    open(my $fh, '<', $file) or die "cannot read $file: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;

    # Where the scripts run unwrapped, if they do: from launchers, below.
    if ($text =~ /\@scripts\@/) {
        $launcherDir = tempdir("hydra-test-launchers-XXXXXX", TMPDIR => 1, CLEANUP => 1);
        $text =~ s/\@scripts\@/$launcherDir/g;
    }
    decode_json($text);
};
writeLaunchers() if defined $launcherDir;

sub shellQuote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub onPath {
    my ($name) = @_;
    return $name if $name =~ m{/};
    for my $dir (split /:/, $ENV{PATH} // "") {
        return "$dir/$name" if -x "$dir/$name";
    }
    die "cannot find `$name' on the test's PATH\n";
}

# Run unwrapped from the source tree, each script gets a launcher doing what
# its wrapper would: set the script's own variables, and run it. A Perl one
# runs with this Perl, since its `#! /usr/bin/env perl` would need a `PATH`
# its caller may not have.
sub writeLaunchers {
    my $scriptDir = $ENV{HYDRA_TEST_SCRIPT_DIR}
        or die "HYDRA_TEST_SCRIPT_DIR is not set, but HYDRA_TEST_PROGRAM_ENV refers to it\n";
    my $perl = onPath($^X);
    opendir(my $dh, $scriptDir) or die "cannot read $scriptDir: $!\n";
    for my $name (grep { !/^\./ } readdir $dh) {
        my $script = "$scriptDir/$name";
        open(my $fh, '<', $script) or die "cannot read $script: $!\n";
        my $shebang = <$fh> // "";
        close $fh;

        # Wrappers set variables, but leave `PATH` alone.
        my $env = $programEnv->{$name} // {};
        my $exports = join "",
            map { "export $_=" . shellQuote($env->{$_}) . "\n" }
            sort grep { $_ ne 'PATH' } keys %$env;
        my @run = $shebang =~ /\bperl\b/ ? ($perl, $script) : ($script);

        my $launcher = "$launcherDir/$name";
        open(my $out, '>', $launcher) or die "cannot write $launcher: $!\n";
        print $out "#! /bin/sh\n" . $exports
            . "exec " . join(" ", map { shellQuote($_) } @run) . " \"\$\@\"\n";
        close $out;
        chmod 0755, $launcher;
    }
    closedir $dh;
}

# The test process itself is the map's `hydra-tests`, keeping its own `PATH`.
{
    my $env = $programEnv->{'hydra-tests'}
        or die "HYDRA_TEST_PROGRAM_ENV says nothing for the test process, `hydra-tests'\n";
    $ENV{$_} = $env->{$_} for grep { $_ ne 'PATH' } keys %$env;
}

sub resolve {
    my ($name) = @_;
    return "$launcherDir/$name" if defined $launcherDir && -e "$launcherDir/$name";
    return onPath($name);
}

# Run `$code` with the environment `$cmd`'s program would have, if it is one
# of Hydra's. `$cmd` is an array ref whose first element names the program;
# that is made absolute here, from the test's `PATH`, since the program
# itself may not get one.
sub withProgramEnv {
    my ($cmd, $code) = @_;
    my $env = $programEnv->{basename($cmd->[0])};
    return $code->() unless defined $env;

    $cmd->[0] = resolve($cmd->[0]);
    local %ENV = %ENV;
    delete $ENV{$_} for grep { isProgramVar($_) } keys %ENV;
    delete $ENV{PATH};
    @ENV{keys %$env} = values %$env;
    return $code->();
}

1;
