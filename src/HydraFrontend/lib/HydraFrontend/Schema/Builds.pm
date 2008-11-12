package HydraFrontend::Schema::Builds;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Builds");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "finished",
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
  "system",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to(
  "project",
  "HydraFrontend::Schema::Projects",
  { name => "project" },
);
__PACKAGE__->belongs_to(
  "jobset",
  "HydraFrontend::Schema::Jobsets",
  { name => "jobset", project => "project" },
);
__PACKAGE__->has_many(
  "buildschedulinginfoes",
  "HydraFrontend::Schema::Buildschedulinginfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildresultinfoes",
  "HydraFrontend::Schema::Buildresultinfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_builds",
  "HydraFrontend::Schema::Buildinputs",
  { "foreign.build" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "HydraFrontend::Schema::Buildinputs",
  { "foreign.dependency" => "self.id" },
);
__PACKAGE__->has_many(
  "buildlogs",
  "HydraFrontend::Schema::Buildlogs",
  { "foreign.build" => "self.id" },
);
__PACKAGE__->has_many(
  "buildsteps",
  "HydraFrontend::Schema::Buildsteps",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildproducts",
  "HydraFrontend::Schema::Buildproducts",
  { "foreign.build" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-12 15:09:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:1fLVr/70ZuAOfnMp3rMzxg

__PACKAGE__->has_many(dependents => 'HydraFrontend::Schema::Buildinputs', 'dependency');

__PACKAGE__->has_many(inputs => 'HydraFrontend::Schema::Buildinputs', 'build');

__PACKAGE__->belongs_to(
  "schedulingInfo",
  "HydraFrontend::Schema::Buildschedulinginfo",
  { id => "id" },
);

__PACKAGE__->belongs_to(
  "resultInfo",
  "HydraFrontend::Schema::Buildresultinfo",
  { id => "id" },
);

1;
