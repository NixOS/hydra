package Hydra::Schema::UserRoles;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::UserRoles

=cut

__PACKAGE__->table("UserRoles");

=head1 ACCESSORS

=head2 username

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 role

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "username",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "role",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("username", "role");

=head1 RELATIONS

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


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:qEshVHXf4YQ0SEVeZ9cVLQ

1;
