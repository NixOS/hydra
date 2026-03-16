use utf8;
package Hydra::Schema::Result::BuildProducts;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::BuildProducts

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

=head1 TABLE: C<buildproducts>

=cut

__PACKAGE__->table("buildproducts");

=head1 ACCESSORS

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 productnr

  data_type: 'integer'
  is_nullable: 0

=head2 type

  data_type: 'text'
  is_nullable: 0

=head2 subtype

  data_type: 'text'
  is_nullable: 0

=head2 filesize

  data_type: 'bigint'
  is_nullable: 1

=head2 sha256hash

  data_type: 'text'
  is_nullable: 1

=head2 path

  data_type: 'text'
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 defaultpath

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "productnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "text", is_nullable => 0 },
  "subtype",
  { data_type => "text", is_nullable => 0 },
  "filesize",
  { data_type => "bigint", is_nullable => 1 },
  "sha256hash",
  { data_type => "text", is_nullable => 1 },
  "path",
  { data_type => "text", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "defaultpath",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</build>

=item * L</productnr>

=back

=cut

__PACKAGE__->set_primary_key("build", "productnr");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Result::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:6vyZPg5I2zbgpw1a6JsVjw

my %hint = (
    columns => [
        'type',
        'subtype',
        'name',
        'filesize',
        'sha256hash',
        'path',
        'defaultpath'
    ],
);

sub json_hint {
    return \%hint;
}

1;
