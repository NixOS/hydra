package Hydra::Helper::Nix;

use strict;


sub isValidPath {
    my $path = shift;
    $SIG{CHLD} = 'DEFAULT'; # !!! work around system() failing if SIGCHLD is ignored
    return system("nix-store --check-validity $path") == 0;
}


1;

