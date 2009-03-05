#!/var/run/current-system/sw/bin/perl -w

use strict;
use Hydra::Helper::Nix;

my $hydraHome = $ENV{"HYDRA_HOME"};
die "The HYDRA_HOME environment variable is not set!\n" unless defined $hydraHome;

my $hydraData = $ENV{"HYDRA_DATA"};
mkdir $hydraData unless -d $hydraData;

my $dbPath = getHydraPath . "/hydra.sqlite";

system("sqlite3 $dbPath < $hydraHome/sql/hydra.sql") == 0
    or warn "Cannot initialise database in $dbPath";
