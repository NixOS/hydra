package Hydra::Helper::Escape;

use strict;
use warnings;
use base qw(Exporter);
use Hydra::Helper::AttributeSet;

our @EXPORT = qw(escapeString escapeAttributePath);

sub escapeString {
    my ($s) = @_;
    $s =~ s|\\|\\\\|g;
    $s =~ s|\"|\\\"|g;
    $s =~ s|\$|\\\$|g;
    return "\"" . $s . "\"";
}

sub escapeAttributePath {
    my ($s) = @_;

    return join ".", map { escapeString($_) } Hydra::Helper::AttributeSet::splitPath($s);
}
