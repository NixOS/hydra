package Hydra::Math;

use strict;
use warnings;
use List::Util qw(min);
use Exporter 'import';
our @EXPORT_OK = qw(exponential_backoff);

sub exponential_backoff {
    my ($attempts) = @_;
    my $clamp = min(10, $attempts);
    return 2 ** $clamp;
}

1;
