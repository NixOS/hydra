use utf8;
package Hydra::Schema::Result::TaskRetries;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::TaskRetries

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<taskretries>

=cut

__PACKAGE__->table("taskretries");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'taskretries_id_seq'

=head2 channel

  data_type: 'text'
  is_nullable: 0

=head2 pluginname

  data_type: 'text'
  is_nullable: 0

=head2 payload

  data_type: 'text'
  is_nullable: 0

=head2 attempts

  data_type: 'integer'
  is_nullable: 0

=head2 retry_at

  data_type: 'integer'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "taskretries_id_seq",
  },
  "channel",
  { data_type => "text", is_nullable => 0 },
  "pluginname",
  { data_type => "text", is_nullable => 0 },
  "payload",
  { data_type => "text", is_nullable => 0 },
  "attempts",
  { data_type => "integer", is_nullable => 0 },
  "retry_at",
  { data_type => "integer", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 16:30:59
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4MC8UnsgrvJVRrIURvSH5A

use Hydra::Math qw(exponential_backoff);

sub requeue {
  my ($self) = @_;

  $self->update({
    attempts => $self->attempts + 1,
    retry_at => time() + exponential_backoff($self->attempts + 1),
  });

}

1;
