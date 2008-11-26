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


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-26 20:02:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:BgF6FK+9d7+cc72sp6pfCQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
