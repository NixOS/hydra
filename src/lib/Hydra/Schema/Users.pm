package Hydra::Schema::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Users");
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
);
__PACKAGE__->set_primary_key("username");
__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
);
__PACKAGE__->has_many(
  "projects",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_09 @ 2009-11-17 16:04:13
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:oBiKpCxHGZcGujhY/ZbbxA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
