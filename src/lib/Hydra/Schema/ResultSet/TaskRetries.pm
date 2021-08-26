package Hydra::Schema::ResultSet::TaskRetries;

use strict;
use warnings;
use utf8;
use base 'DBIx::Class::ResultSet';
use List::Util qw(max);

=head2 get_seconds_to_next_retry

Query the database to identify how soon the next retryable task is due
for being attempted again.

If there are no tasks to be reattempted it returns undef.

If a task's scheduled retry has passed, it returns 0.

Otherwise, returns the number of seconds from now to look for work.

=cut
sub get_seconds_to_next_retry {
    my ($self) = @_;

    my $next_retry = $self->search(
        {}, # any task
        {
            order_by => {
                -asc => 'retry_at'
            },
            rows => 1,
        }
    )->get_column('retry_at')->first;

    if (defined($next_retry)) {
        return max(0, $next_retry - time());
    } else {
        return undef;
    }
}

1;
