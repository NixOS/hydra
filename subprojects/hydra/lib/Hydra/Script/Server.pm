package Hydra::Script::Server;
use Moose;
use namespace::autoclean;

extends 'CatalystX::Script::Server::Starman';

# When systemd socket activation is in use, swap Starman's Net::Server
# personality to one that adopts the passed-in file descriptors.
# This is equivalent to https://github.com/miyagawa/Starman/pull/156;
# once that is merged and released, this block can be removed.
before 'run' => sub {
    if ($ENV{LISTEN_FDS}) {
        require Net::Server::Systemd::PreFork;
        @Starman::Server::ISA = qw(Net::Server::Systemd::PreFork);
    }
};

1;
