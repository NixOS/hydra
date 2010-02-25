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
