#!/usr/bin/env perl

use strict;
use warnings;
use Cwd 'abs_path';
use File::Basename;

my $dirname = abs_path(dirname(__FILE__) . "/../..");

print STDERR "Executing perlcritic against $dirname\n";
chdir($dirname) or die "Failed to enter $dirname\n";

exec(
    "perlcritic",
    "--quiet",
    "subprojects/hydra/",
    "subprojects/hydra-tests/",
    "subprojects/hydra-linters/",
    "subprojects/nix-perl",
) or die "Failed to execute perlcritic.";
