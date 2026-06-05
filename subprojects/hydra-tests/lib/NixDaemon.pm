use warnings;
use strict;

package NixDaemon;
use File::Path qw(make_path);
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(start_nix_daemon);

# Start a nix daemon for the given store config and register it in a
# ProcessGroup so its logs are pumped alongside the other processes.
sub start_nix_daemon {
    my ($store, $pg, $label) = @_;
    make_path($store->{nix_state_dir});

    my $harness = $pg->spawn($label, ["nix-daemon"], env => {
        NIX_REMOTE              => $store->{nix_store_uri},
        NIX_STORE_DIR           => $store->{nix_store_dir},
        NIX_STATE_DIR           => $store->{nix_state_dir},
        NIX_CONF_DIR            => $store->{nix_conf_dir},
        NIX_DAEMON_SOCKET_PATH  => $store->{nix_daemon_socket_path},
        NIX_CONFIG              => "trusted-users = *",
    });
    my $socket = $store->{nix_daemon_socket_path};
    for (1..50) {
        last if -S $socket;
        select(undef, undef, undef, 0.1);
    }
    -S $socket or die "nix-daemon did not start: $socket\n";
    return $harness;
}

1;
