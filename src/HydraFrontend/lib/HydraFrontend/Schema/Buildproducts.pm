package HydraFrontend::Schema::Buildproducts;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("buildProducts");
__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
  "subtype",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("build", "path");
__PACKAGE__->belongs_to("build", "HydraFrontend::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-10 14:25:07
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:LaXQ4zxxvzdKFBRVcjMdMQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
