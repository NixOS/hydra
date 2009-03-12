package Hydra::Schema::BuildResultInfo;

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
  "logfile",
  { data_type => "text", is_nullable => 0, size => undef },
  "releasename",
  { data_type => "text", is_nullable => 0, size => undef },
  "keep",
  { data_type => "integer", is_nullable => 0, size => undef },
  "faileddepbuild",
  { data_type => "integer", is_nullable => 0, size => undef },
  "faileddepstepnr",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" });


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-12 14:17:32
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:xvSDu+FkyKp5wTAEGmiKOw

__PACKAGE__->belongs_to(
  "failedDep",
  "Hydra::Schema::BuildSteps",
  { id => "faileddepbuild", stepnr => "faileddepstepnr" },
);

1;
