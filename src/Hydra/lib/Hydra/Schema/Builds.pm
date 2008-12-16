package Hydra::Schema::Builds;

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
  "nixname",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "system",
  { data_type => "text", is_nullable => 0, size => undef },
  "longdescription",
  { data_type => "text", is_nullable => 0, size => undef },
  "license",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
);
__PACKAGE__->has_many(
  "buildschedulinginfoes",
  "Hydra::Schema::Buildschedulinginfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildresultinfoes",
  "Hydra::Schema::Buildresultinfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::Buildsteps",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::Buildinputs",
  { "foreign.build" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::Buildinputs",
  { "foreign.dependency" => "self.id" },
);
__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::Buildproducts",
  { "foreign.build" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-12-16 15:42:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:+1cH3km/2qF9kVXzvuLCpQ

__PACKAGE__->has_many(dependents => 'Hydra::Schema::Buildinputs', 'dependency');

__PACKAGE__->many_to_many(dependentBuilds => 'dependents', 'build');

__PACKAGE__->has_many(inputs => 'Hydra::Schema::Buildinputs', 'build');

__PACKAGE__->belongs_to(
  "schedulingInfo",
  "Hydra::Schema::Buildschedulinginfo",
  { id => "id" },
);

__PACKAGE__->belongs_to(
  "resultInfo",
  "Hydra::Schema::Buildresultinfo",
  { id => "id" },
);

1;
