package Hydra::Schema::BuildProducts;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildProducts");
__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_nullable => 0, size => undef },
  "productnr",
  { data_type => "integer", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
  "subtype",
  { data_type => "text", is_nullable => 0, size => undef },
  "filesize",
  { data_type => "integer", is_nullable => 0, size => undef },
  "sha1hash",
  { data_type => "text", is_nullable => 0, size => undef },
  "sha256hash",
  { data_type => "text", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("build", "productnr");
__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-04 14:50:30
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:FFVpdoV0vBLhF9yyKJSoTA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
