# This module is from https://github.com/miyagawa/Starman/pull/156. Once
# that PR is merged, this should be removed.
package Net::Server::Systemd::PreFork;

use strict;
use warnings;

use Net::Server::PreFork;
use Net::Server::Proto;
use Net::Server::Proto::TCP;
use Net::Server::Proto::UNIX;
use Socket qw(AF_INET6);

use base qw(Net::Server::PreFork);

use constant SD_LISTEN_FDS_START => 3;

sub pre_bind {
    my $self = shift;
    my $prop = $self->{server};

    # Net::Server::Proto::TCP starts life inheriting from IO::Socket::INET (IPv4
    # only). Normally its constructor (::object) swaps @ISA to an IPv6-capable
    # class (IO::Socket::IP) at runtime. Since we bypass that constructor — we
    # already have bound fds from systemd — we trigger the same swap here. This
    # is a global, idempotent mutation; it's safe because all TCP sockets in
    # this process need IPv6 support regardless.
    @Net::Server::Proto::TCP::ISA = (Net::Server::Proto->ipv6_package($self))
        if $Net::Server::Proto::TCP::ISA[0] eq 'IO::Socket::INET';

    my $count = $ENV{LISTEN_FDS}
        or $self->fatal("LISTEN_FDS not set");

    # Validate LISTEN_PID if set and non-empty.
    if (my $pid = $ENV{LISTEN_PID}) {
        $pid == $$
            or $self->fatal("LISTEN_PID ($pid) does not match our PID ($$)");
    }

    my $first_fd = $ENV{LISTEN_FDS_FIRST_FD} || SD_LISTEN_FDS_START;

    for my $i (0 .. $count - 1) {
        my $fd = $first_fd + $i;

        # We use fdopen (not new_from_fd) because we need the socket to be a
        # Net::Server::Proto::TCP object — it already has the NS_* accessor
        # methods that Net::Server's event loop expects, and after the @ISA swap
        # above it inherits from IO::Socket::IP which handles both IPv4 and IPv6
        # accept/address parsing correctly.
        my $sock = Net::Server::Proto::TCP->new();
        $sock->fdopen($fd, 'r')
            or $self->fatal("failed to fdopen listening socket fd $fd: $!");

        # Detect the actual socket family so Net::Server knows how to format
        # addresses in log messages, etc.
        my $sockname = getsockname($sock)
            or $self->fatal("getsockname failed on fd $fd: $!");
        my $family = Socket::sockaddr_family($sockname);

        if ($family == AF_INET6) {
            $sock->NS_ipv('6');
        } elsif ($family == Socket::AF_INET) {
            $sock->NS_ipv('4');
        } else {
            # Not an IP socket — assume Unix domain. Re-fdopen into the correct
            # Proto class since Proto::TCP can't handle Unix accept.
            $sock = Net::Server::Proto::UNIX->new();
            $sock->fdopen($fd, 'r')
                or $self->fatal("failed to fdopen listening socket fd $fd: $!");
        }

        push @{$prop->{sock}}, $sock;
    }

    $prop->{multi_port} = 1 if @{$prop->{sock}} > 1;
}

# Override bind to skip actually binding (already done by systemd) and just set
# up IO::Select if there are multiple listening sockets.
sub bind {
    my $self = shift;
    my $prop = $self->{server};

    if (@{$prop->{sock}} > 1) {
        $prop->{multi_port} = 1;
        $prop->{select} = IO::Select->new();
        for (@{$prop->{sock}}) {
            $prop->{select}->add($_);
        }
    } else {
        $prop->{multi_port} = undef;
        $prop->{select}     = undef;
    }
}

# Use close(2) rather than shutdown(2). See Net::Server::SS::PreFork for
# rationale — shutdown on a shared fd closes it for all forked workers.
sub shutdown_sockets {
    my $self = shift;
    my $prop = $self->{server};

    for my $sock (@{$prop->{sock}}) {
        $sock->close;
    }

    $prop->{sock} = [];
    return 1;
}

1;
