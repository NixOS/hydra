package Hydra::PostgresListener;

use strict;
use warnings;
use IO::Select;

=head1 Hydra::PostgresListener

An abstraction around using Postgres' LISTEN / NOTIFY in an event loop.

=cut

=head2 new

Arguments:

=over 1

=item C<$dbh>
L<DBI::db> The database connection.

=back

=cut

sub new {
    my ($self, $dbh) = @_;
    my $sel = IO::Select->new($dbh->func("getfd"));

    return bless {
        "dbh" => $dbh,
        "sel" => $sel,
    }, $self;
}

=head2 subscribe

Subscribe to the named channel for messages

Arguments:

=over 1

=item C<$channel>

The channel name.

=back

=cut

sub subscribe {
    my ($self, $channel) = @_;
    $channel = $self->{'dbh'}->quote_identifier($channel);
    $self->{'dbh'}->do("listen $channel");
}

=head2 block_for_messages

Wait for messages to arrive within the specified timeout.

Arguments:

=over 1

=item C<$timeout>
The maximum number of seconds to wait for messages.

Optional: if unspecified, block forever.

=back

Returns: a sub, call the sub repeatedly to get a message. The sub
will return undef when there are no pending messages.

Example:

  my $events = $listener->block_for_messages();
  while (my $message = $events->()) {
    ...
  }

=cut

sub block_for_messages {
    my ($self, $timeout) = @_;

    $self->{'sel'}->can_read($timeout);

    return sub {
        my $notify = $self->{'dbh'}->func("pg_notifies");
        if (defined($notify)) {
            my ($channelName, $pid, $payload) = @$notify;
            return {
                channel => $channelName,
                pid     => $pid,
                payload => $payload,
            };
        }
        else {
            return undef;
        }
    }
}

1;
