package Nix::Utils;

use utf8;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT = qw(readFile);

sub readFile {
    local $/ = undef;
    my ($fn) = @_;
    open my $fh, "<", $fn or die "cannot open file '$fn': $!";
    my $s = <$fh>;
    close $fh or die;
    return $s;
}

1;
