package HydraFrontend::Schema::Inputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("inputs");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "build",
  { data_type => "integer", is_nullable => 0, size => undef },
  "job",
  { data_type => "integer", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
  "uri",
  { data_type => "text", is_nullable => 0, size => undef },
  "revision",
  { data_type => "integer", is_nullable => 0, size => undef },
  "tag",
  { data_type => "text", is_nullable => 0, size => undef },
  "value",
  { data_type => "text", is_nullable => 0, size => undef },
  "dependency",
  { data_type => "integer", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("build", "HydraFrontend::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-10 14:25:07
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:A3Is4VTFkTl2DzrYjzdrZA

__PACKAGE__->belongs_to("dependency", "HydraFrontend::Schema::Builds", { id => "dependency" });

1;
