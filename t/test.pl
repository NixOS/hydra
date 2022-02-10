#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
# THIS IS A GENERATED YATH RUNNER TEST
use strict;
use warnings;

use lib 'lib';
BEGIN {
    use File::Which qw(which);
    $App::Yath::Script::SCRIPT = which 'yath';
}
use App::Yath::Util qw/find_yath/;
use List::SomeUtils qw(none);

if (defined($ENV{"NIX_BUILD_CORES"})
    and not defined($ENV{"YATH_JOB_COUNT"})
    and not defined($ENV{"T2_HARNESS_JOB_COUNT"})
    and not defined($ENV{"T2_HARNESS_JOB_COUNT"})) {
    $ENV{"YATH_JOB_COUNT"} = $ENV{"NIX_BUILD_CORES"};
    print STDERR "test.pl: Defaulting \$YATH_JOB_COUNT to \$NIX_BUILD_CORES (${\$ENV{'NIX_BUILD_CORES'}})\n";
}

system($^X, find_yath(), '-D', 'test', '--default-search' => './', @ARGV);
my $exit = $?;

# This makes sure it works with prove.
print "1..1\n";
print "not " if $exit;
print "ok 1 - Passed tests when run by yath\n";
print STDERR "yath exited with $exit" if $exit;

exit($exit ? 255 : 0);
