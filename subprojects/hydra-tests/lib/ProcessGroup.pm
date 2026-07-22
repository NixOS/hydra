use warnings;
use strict;

package ProcessGroup;

# A lightweight wrapper around a set of IPC::Run harnesses with
# labelled log flushing, pump, and ordered teardown.
#
# Usage:
#   my $pg = ProcessGroup->new;
#   $pg->spawn("queue-runner", ["hydra-queue-runner", ...], env => { ... });
#   $pg->pump_logs;
#   $pg->stop;   # or let DESTROY handle it

use IPC::Run;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw();

sub new {
    my ($class, %opts) = @_;
    bless {
        procs => {},
        order => [],
        env   => $opts{env} // {},
    }, $class;
}

# Spawn a labelled child process and register it.
#
# Options:
#   env => { KEY => VAL, ... }  extra env vars merged with the group default
#   init => sub { ... }         passed to IPC::Run::start as init callback
sub spawn {
    my ($self, $key, $cmd, %opts) = @_;
    my %env = (%{$self->{env}}, %{$opts{env} // {}});
    my ($in, $out, $err) = ("", "", "");
    my $harness;
    {
        local @ENV{keys %env} = values %env;
        local $ENV{NO_COLOR} = "1";
        my @extra;
        push @extra, (init => $opts{init}) if $opts{init};
        $harness = IPC::Run::start($cmd, \$in, \$out, \$err, @extra);
    }
    $self->{procs}{$key} = {
        label   => $key,
        harness => $harness,
        out     => \$out,
        err     => \$err,
    };
    push @{$self->{order}}, $key;
    return $harness;
}

# Pump all harnesses and flush any complete log lines to stderr.
sub pump_logs {
    my ($self) = @_;
    for my $key (@{$self->{order}}) {
        my $p = $self->{procs}{$key} or next;
        eval { $p->{harness}->pump_nb };
        _flush_proc($p);
    }
}

# Return the harness for a given key, or undef.
sub harness {
    my ($self, $key) = @_;
    my $p = $self->{procs}{$key} or return undef;
    return $p->{harness};
}

# Return the stdout buffer ref for a given key.
sub stdout_ref {
    my ($self, $key) = @_;
    return $self->{procs}{$key}{out};
}

# Return the stderr buffer ref for a given key.
sub stderr_ref {
    my ($self, $key) = @_;
    return $self->{procs}{$key}{err};
}

# Kill all processes in reverse spawn order and flush final output.
sub stop {
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    for my $key (reverse @{$self->{order}}) {
        my $p = $self->{procs}{$key} or next;
        eval { $p->{harness}->kill_kill };
        _flush_proc($p, 1);
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->stop;
}

# --- Internal helpers ---

sub _flush_stream {
    my ($label, $stream, $buf_ref, $final) = @_;
    return if $$buf_ref eq "";
    utf8::decode($$buf_ref) or warn "Invalid unicode in $label $stream.";
    while ($$buf_ref =~ s/^([^\n]*)\n//) {
        print STDERR "[$label $stream] $1\n";
    }
    if ($final && $$buf_ref ne "") {
        print STDERR "[$label $stream] $$buf_ref\n";
        $$buf_ref = "";
    }
}

sub _flush_proc {
    my ($p, $final) = @_;
    _flush_stream($p->{label}, "stdout", $p->{out}, $final);
    _flush_stream($p->{label}, "stderr", $p->{err}, $final);
}

1;
