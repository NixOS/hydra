package Hydra::Schema::Users;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Users");
__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0, size => undef },
  "fullname",
  { data_type => "text", is_nullable => 0, size => undef },
  "emailaddress",
  { data_type => "text", is_nullable => 0, size => undef },
  "password",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("username");
__PACKAGE__->has_many(
  "projects",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
);
__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-13 13:33:20
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Gw6X/Et2+whq/S7o63zF8Q


# You can replace this text with custom content, and it will be preserved on regeneration
1;
