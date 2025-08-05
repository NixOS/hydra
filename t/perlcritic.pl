#!/usr/bin/env perl

use strict;
use warnings;
use Cwd 'abs_path';
use File::Basename;

my $dirname = abs_path(dirname(__FILE__) . "/..");

print STDERR "Executing perlcritic against $dirname\n";
chdir($dirname) or die "Failed to enter $dirname\n";

# Add src/lib to PERL5LIB so perlcritic can find our custom policies
$ENV{PERL5LIB} = "src/lib" . ($ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : "");

exec("perlcritic", "--quiet", ".") or die "Failed to execute perlcritic.";
