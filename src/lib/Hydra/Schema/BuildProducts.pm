package Hydra::Schema::BuildProducts;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildProducts

=cut

__PACKAGE__->table("BuildProducts");

=head1 ACCESSORS

=head2 build

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 productnr

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 type

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 subtype

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 filesize

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 sha1hash

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 sha256hash

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 path

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 name

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 defaultpath

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=cut

__PACKAGE__->add_columns(
  "build",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "productnr",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "type",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "subtype",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "filesize",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "sha1hash",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "sha256hash",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "path",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "defaultpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("build", "productnr");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" }, {});


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:5XWD8BZb3WeSJwKirHGhWA

# You can replace this text with custom content, and it will be preserved on regeneration
1;
