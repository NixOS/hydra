package Hydra::Schema::Buildsteps;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildSteps");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "stepnr",
  { data_type => "integer", is_nullable => 0, size => undef },
  "type",
  { data_type => "integer", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "logfile",
  { data_type => "text", is_nullable => 0, size => undef },
  "busy",
  { data_type => "integer", is_nullable => 0, size => undef },
  "status",
  { data_type => "integer", is_nullable => 0, size => undef },
  "errormsg",
  { data_type => "text", is_nullable => 0, size => undef },
  "starttime",
  { data_type => "integer", is_nullable => 0, size => undef },
  "stoptime",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id", "stepnr");
__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-26 20:02:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:kFD90OFRM1aqVVCBCh/geA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
