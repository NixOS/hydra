use utf8;
package Hydra::Schema::AggregateConstituents;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::AggregateConstituents

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

=head1 TABLE: C<aggregateconstituents>

=cut

__PACKAGE__->table("aggregateconstituents");

=head1 ACCESSORS

=head2 aggregate

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 constituent

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "aggregate",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "constituent",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</aggregate>

=item * L</constituent>

=back

=cut

__PACKAGE__->set_primary_key("aggregate", "constituent");

=head1 RELATIONS

=head2 aggregate

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "aggregate",
  "Hydra::Schema::Builds",
  { id => "aggregate" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 constituent

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "constituent",
  "Hydra::Schema::Builds",
  { id => "constituent" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-02-06 12:22:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:bQfQoSstlaFy7zw8i1R+ow


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
