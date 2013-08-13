use utf8;
package Hydra::Schema::AggregateMembers;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::AggregateMembers

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

=head1 TABLE: C<AggregateMembers>

=cut

__PACKAGE__->table("AggregateMembers");

=head1 ACCESSORS

=head2 aggregate

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 member

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "aggregate",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "member",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</aggregate>

=item * L</member>

=back

=cut

__PACKAGE__->set_primary_key("aggregate", "member");

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

=head2 member

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "member",
  "Hydra::Schema::Builds",
  { id => "member" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-08-13 22:17:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:jHJtO2baXiprv0OcWCLZ+w


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
