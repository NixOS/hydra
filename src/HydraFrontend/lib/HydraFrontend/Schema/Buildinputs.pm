package HydraFrontend::Schema::Buildinputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("buildInputs");
__PACKAGE__->add_columns(
  "buildid",
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
  "inputid",
  { data_type => "integer", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
  "value",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("buildid", "name");
__PACKAGE__->belongs_to(
  "buildid",
  "HydraFrontend::Schema::Builds",
  { id => "buildid" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-08 23:34:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2XeATQWeO3i3eSHlquS2QA

__PACKAGE__->belongs_to(
  "build",
  "HydraFrontend::Schema::Builds",
  { id => "inputid" },
);

1;
