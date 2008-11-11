package HydraFrontend::Schema::Buildlogs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildLogs");
__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_nullable => 0, size => undef },
  "logphase",
  { data_type => "text", is_nullable => 0, size => undef },
  "path",
  { data_type => "text", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("build", "logphase");
__PACKAGE__->belongs_to("build", "HydraFrontend::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-11 13:41:38
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ZOxJeT+ltgyc/zuDl9aEDQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
