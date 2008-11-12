package HydraFrontend::Schema::Buildinputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildInputs");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "build",
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
__PACKAGE__->belongs_to(
  "dependency",
  "HydraFrontend::Schema::Builds",
  { id => "dependency" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-12 15:09:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gB3bnV6S6yuAk1ojYmaI8g


# You can replace this text with custom content, and it will be preserved on regeneration
1;
