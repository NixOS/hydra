# Sort all columns within CREATE TABLE statements.

use v5.10;
use strict;
use List::Util qw(all);

while (<<>>) {
    if (/^CREATE TABLE .*\(/) {
        print;
        my @table;
        while (<<>>) {
            last if /^\);/;
            chomp;
            push @table, s/,$//r;
        }
        say join ','.$/, sort {
            return $a cmp $b if all { /^\*CONSTRAINT/ } ($a, $b);
            return 1 if $a =~ /^\s*CONSTRAINT/;
            return -1 if $b =~ /^\s*CONSTRAINT/;
            return $a cmp $b;
        } @table;
    }
    print;
}
