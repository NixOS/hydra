use utf8;
package Hydra::Schema::ProjectMembers;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::ProjectMembers

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<ProjectMembers>

=cut

__PACKAGE__->table("ProjectMembers");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 username

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "username",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</username>

=back

=cut

__PACKAGE__->set_primary_key("project", "username");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 username

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to(
  "username",
  "Hydra::Schema::Users",
  { username => "username" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:09p6h8c3+hRIjw3XmX15rA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
