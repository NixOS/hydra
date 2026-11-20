use warnings;
use strict;
use IPC::Run;

package Hydra::Helper::Exec;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    captureStdoutStderr
    captureStdoutStderrWithStdin
    expectOkay
    pluginPath
    program
);

# Where to find `$name`, one of the programs Hydra runs.
#
# Hydra does not look its programs up on `PATH`. Each is named by its own
# variable, `HYDRA_PROGRAM_<NAME>`: the name upper-cased, with `-` as `_`.
# Whoever runs Hydra -- a wrapper, the NixOS module, the test suite -- sets
# them, and a missing one is an error rather than whatever `PATH` turns up.
# The Rust side follows the same convention, in the `hydra-programs` crate.
sub program {
    my ($name) = @_;
    (my $var = "HYDRA_PROGRAM_" . uc $name) =~ tr/-/_/;
    my $path = $ENV{$var};
    die "$var is not set: it must name the `$name' program\n"
        unless defined $path && $path ne "";
    return $path;
}

# The `PATH` for what plugins from outside Hydra, and the commands
# `RunCommand` runs, may run, from `HYDRA_PLUGIN_PATH`. Hydra's own processes
# have no `PATH`, since Hydra does not know in advance what these will want;
# whoever deploys them says, and this is where it goes. Use it as
# `local $ENV{PATH} = pluginPath();` around running such a command.
sub pluginPath {
    return $ENV{HYDRA_PLUGIN_PATH} // "";
}

sub expectOkay {
    my ($timeout, @cmd) = @_;

    my ($res, $stdout, $stderr) = captureStdoutStderrWithStdin($timeout, \@cmd, "");
    if ($res) {
        die <<MSG;
        Failure executing @cmd.

        STDOUT:
        $stdout

        STDERR:
        $stderr
MSG
    }

    1;
}

sub captureStdoutStderr {
    my ($timeout, @cmd) = @_;

    return captureStdoutStderrWithStdin($timeout, \@cmd, "");
}

sub captureStdoutStderrWithStdin {
    my ($timeout, $cmd, $stdin) = @_;
    my $stdout;
    my $stderr;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $timeout;
        IPC::Run::run($cmd, \$stdin, \$stdout, \$stderr);
        alarm 0;
        1;
    } or do {
        die "exec @$cmd: $@" unless $@ eq "timeout\n"; # propagate unexpected errors
        return (-1, $stdout, ($stderr // "") . "timeout\n");
    };

    return ($?, $stdout, $stderr);
}
