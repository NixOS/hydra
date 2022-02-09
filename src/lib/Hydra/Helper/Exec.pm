use warnings;
use strict;
use IPC::Run;

package Hydra::Helper::Exec;
our @ISA = qw(Exporter);
our @EXPORT = qw(
    captureStdoutStderr
    captureStdoutStderrWithStdin
);

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
        die unless $@ eq "timeout\n"; # propagate unexpected errors
        return (-1, $stdout, ($stderr // "") . "timeout\n");
    };

    return ($?, $stdout, $stderr);
}
