package Hydra::Schema::BuildSchedulingInfo;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildSchedulingInfo");
__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "busy",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "locker",
  { data_type => "text", default_value => "''", is_nullable => 0, size => undef },
  "logfile",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "starttime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" });


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-15 23:14:39
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:RcdX5dHefBQnxQYbMxNF/w


# You can replace this text with custom content, and it will be preserved on regeneration
1;
