use utf8;
package Hydra::Schema::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Users

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<Users>

=cut

__PACKAGE__->table("Users");

=head1 ACCESSORS

=head2 username

  data_type: 'text'
  is_nullable: 0

=head2 fullname

  data_type: 'text'
  is_nullable: 1

=head2 emailaddress

  data_type: 'text'
  is_nullable: 0

=head2 password

  data_type: 'text'
  is_nullable: 0

=head2 emailonerror

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0 },
  "fullname",
  { data_type => "text", is_nullable => 1 },
  "emailaddress",
  { data_type => "text", is_nullable => 0 },
  "password",
  { data_type => "text", is_nullable => 0 },
  "emailonerror",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</username>

=back

=cut

__PACKAGE__->set_primary_key("username");

=head1 RELATIONS

=head2 newsitems

Type: has_many

Related object: L<Hydra::Schema::NewsItems>

=cut

__PACKAGE__->has_many(
  "newsitems",
  "Hydra::Schema::NewsItems",
  { "foreign.author" => "self.username" },
  {},
);

=head2 projectmembers

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "projectmembers",
  "Hydra::Schema::ProjectMembers",
  { "foreign.username" => "self.username" },
  {},
);

=head2 projects

Type: has_many

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->has_many(
  "projects",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
  {},
);

=head2 userroles

Type: has_many

Related object: L<Hydra::Schema::UserRoles>

=cut

__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:3fmr8WMAE9Dg7TKom76YIQ
# These lines were loaded from '/home/rbvermaa/src/hydra/src/lib/Hydra/Schema/Users.pm' found in @INC.
# They are now part of the custom portion of this file
# for you to hand-edit.  If you do not either delete
# this section or remove that file from @INC, this section
# will be repeated redundantly when you re-create this
# file again via Loader!  See skip_load_external to disable
# this feature.

package Hydra::Schema::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Users

=cut

__PACKAGE__->table("Users");

=head1 ACCESSORS

=head2 username

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 fullname

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 emailaddress

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 password

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 emailonerror

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "username",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "fullname",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "emailaddress",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "password",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "emailonerror",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("username");

=head1 RELATIONS

=head2 userroles

Type: has_many

Related object: L<Hydra::Schema::UserRoles>

=cut

__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
);

=head2 projects

Type: has_many

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->has_many(
  "projects",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:vHluB+s1FkpJBPWmpv+wUQ

1;
# End of lines loaded from '/home/rbvermaa/src/hydra/src/lib/Hydra/Schema/Users.pm' 
# These lines were loaded from '/home/rbvermaa/src/hydra/src/lib/Hydra/Schema/Users.pm' found in @INC.
# They are now part of the custom portion of this file
# for you to hand-edit.  If you do not either delete
# this section or remove that file from @INC, this section
# will be repeated redundantly when you re-create this
# file again via Loader!  See skip_load_external to disable
# this feature.

# You can replace this text with custom content, and it will be preserved on regeneration
1;
