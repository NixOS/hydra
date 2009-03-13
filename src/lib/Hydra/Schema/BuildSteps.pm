package Hydra::Schema::BuildSteps;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildSteps");
__PACKAGE__->add_columns(
  "build",
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
__PACKAGE__->set_primary_key("build", "stepnr");
__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-13 13:33:20
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:TtcOwOIZHO0vLSJ1CXF1bA

1;
