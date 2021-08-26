package Hydra::Schema::ResultSet::TaskRetries;

use strict;
use warnings;
use utf8;
use base 'DBIx::Class::ResultSet';
use List::Util qw(max);

sub getSecondsToNextRetry {
    my ($self) = @_;

    my $next_task = $self->find(
        {}, # any task
        {
            order_by => {
                -asc => 'retry_at'
            },
            rows => 1,
        }
    );

    if (defined($next_task)) {
        return max(0, $next_task->retry_at - time());
    } else {
        return undef;
    }
}

1;
