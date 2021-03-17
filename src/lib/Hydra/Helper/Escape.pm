package Hydra::Helper::Escape;

use strict;
use base qw(Exporter);

our @EXPORT = qw(escapeString);

sub escapeString {
    my ($s) = @_;
    $s =~ s|\\|\\\\|g;
    $s =~ s|\"|\\\"|g;
    $s =~ s|\$|\\\$|g;
    return "\"" . $s . "\"";
}
