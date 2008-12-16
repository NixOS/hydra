package Hydra::Schema::Userroles;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("UserRoles");
__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0, size => undef },
  "role",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("username", "role");
__PACKAGE__->belongs_to("username", "Hydra::Schema::Users", { username => "username" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-12-16 15:42:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hXmj8AaIhROVYgDJdV+N9A


# You can replace this text with custom content, and it will be preserved on regeneration
1;
