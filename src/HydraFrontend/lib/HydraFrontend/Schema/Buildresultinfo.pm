package HydraFrontend::Schema::Buildresultinfo;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildResultInfo");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "iscachedbuild",
  { data_type => "integer", is_nullable => 0, size => undef },
  "buildstatus",
  { data_type => "integer", is_nullable => 0, size => undef },
  "errormsg",
  { data_type => "text", is_nullable => 0, size => undef },
  "starttime",
  { data_type => "integer", is_nullable => 0, size => undef },
  "stoptime",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("id", "HydraFrontend::Schema::Builds", { id => "id" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-17 17:09:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:MqQ972Qn6sjoWbbbzmE1cg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
