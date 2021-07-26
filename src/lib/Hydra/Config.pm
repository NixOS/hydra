package Hydra::Config;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(%configGeneralOpts);

my %configGeneralOpts = (-UseApacheInclude => 1, -IncludeAgain => 1);

1;
