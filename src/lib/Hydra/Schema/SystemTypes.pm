package Hydra::Schema::SystemTypes;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("SystemTypes");
__PACKAGE__->add_columns(
  "system",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "maxconcurrent",
  { data_type => "integer", default_value => 2, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("system");


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-21 17:40:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Qb9hjYs3pwR/hv9ds0lbuQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
