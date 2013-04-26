package Hydra::View::TT;

use strict;
use base 'Catalyst::View::TT';
use Hydra::Helper::Nix;

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    PRE_CHOMP => 1,
    POST_CHOMP => 1,
    expose_methods => [qw/log_exists ellipsize/]);

sub log_exists {
    my ($self, $c, $drvPath) = @_;
    my $x = getDrvLogPath($drvPath);
    return defined $x;
}

sub ellipsize {
    my ($self, $c, $s, $n) = @_;
    return length $s <= $n ? $s : substr($s, 0, $n - 3) . "...";
}

1;
