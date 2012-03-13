use utf8;
package Hydra::Schema::NewsItems;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::NewsItems

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<NewsItems>

=cut

__PACKAGE__->table("NewsItems");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

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
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
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

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to("author", "Hydra::Schema::Users", { username => "author" }, {});


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:YRMh0QI4JezFLj7nywGu6Q

1;
