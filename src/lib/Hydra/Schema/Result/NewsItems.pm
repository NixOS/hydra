use utf8;

package Hydra::Schema::Result::NewsItems;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::NewsItems

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

=head1 TABLE: C<newsitems>

=cut

__PACKAGE__->table("newsitems");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'newsitems_id_seq'

=head2 contents

  data_type: 'text'
  is_nullable: 0

=head2 createtime

  data_type: 'integer'
  is_nullable: 0

=head2 author

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
    "id",
    {
        data_type         => "integer",
        is_auto_increment => 1,
        is_nullable       => 0,
        sequence          => "newsitems_id_seq",
    },
    "contents",
    { data_type => "text", is_nullable => 0 },
    "createtime",
    { data_type => "integer", is_nullable => 0 },
    "author",
    { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 author

Type: belongs_to

Related object: L<Hydra::Schema::Result::Users>

=cut

__PACKAGE__->belongs_to(
    "author",
    "Hydra::Schema::Result::Users",
    { username      => "author" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:pJsP4RptP4rTmM2j4B5+oA

1;
