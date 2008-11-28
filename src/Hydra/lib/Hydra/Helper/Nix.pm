package Hydra::Helper::Nix;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(isValidPath getHydraPath getHydraDBPath openHydraDB);


sub isValidPath {
    my $path = shift;
    $SIG{CHLD} = 'DEFAULT'; # !!! work around system() failing if SIGCHLD is ignored
    return system("nix-store --check-validity $path 2> /dev/null") == 0;
}


sub getHydraPath {
    my $dir = $ENV{HYDRA_DATA};
    die "The HYDRA_DATA environment variable is not set!\n" unless defined $dir;
    die "The HYDRA_DATA directory does not exist!\n" unless -d $dir;
    return $dir;
}


sub getHydraDBPath {
    my $path = getHydraPath . '/hydra.sqlite';
    die "The Hydra database ($path) not exist!\n" unless -f $path;
    return "dbi:SQLite:$path";
}


sub openHydraDB {
    my $db = Hydra::Schema->connect(getHydraDBPath, "", "", {});
    $db->storage->dbh->do("PRAGMA synchronous = OFF;");
    return $db;
}


1;
