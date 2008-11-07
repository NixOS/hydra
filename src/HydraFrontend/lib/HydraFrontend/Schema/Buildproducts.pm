package HydraFrontend::Schema::Buildproducts;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("buildProducts");
__PACKAGE__->add_columns(
  "buildid",
  { data_type => "integer", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
  "subtype",
  { data_type => "text", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
  "productnr",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("buildid", "productnr");
__PACKAGE__->belongs_to(
  "buildid",
  "HydraFrontend::Schema::Builds",
  { id => "buildid" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-07 17:44:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4exGa1a3mCSv3b8Lqwu7Hw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
