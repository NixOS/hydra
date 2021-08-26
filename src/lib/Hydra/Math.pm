package Hydra::Math;

use strict;
use warnings;
use List::Util qw(min);
use Exporter 'import';
our @EXPORT_OK = qw(exponential_backoff);

=head2 exponential_backoff

Calculates a number of seconds to wait before reattempting something.

Arguments:

=over 1

=item C<$attempts>

Integer number of attempts made.

=back

=cut
sub exponential_backoff {
    my ($attempt) = @_;
    my $clamp = min(10, $attempt);
    return 2 ** $clamp;
}

1;
