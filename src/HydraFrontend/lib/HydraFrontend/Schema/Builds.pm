package HydraFrontend::Schema::Builds;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("builds");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "timestamp",
  { data_type => "integer", is_nullable => 0, size => undef },
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "jobset",
  { data_type => "text", is_nullable => 0, size => undef },
  "attrname",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
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
  "system",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->has_many(
  "buildproducts",
  "HydraFrontend::Schema::Buildproducts",
  { "foreign.buildid" => "self.id" },
);
__PACKAGE__->has_many(
  "buildlogs",
  "HydraFrontend::Schema::Buildlogs",
  { "foreign.buildid" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs",
  "HydraFrontend::Schema::Buildinputs",
  { "foreign.buildid" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-06 19:19:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:jcNXcVLLxMEddBCUkq5aYg

__PACKAGE__->has_many(dependentBuildInputs => 'HydraFrontend::Schema::Buildinputs', 'inputid');

1;
