package Hydra::Schema::Jobs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Jobs");
__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "jobset",
  { data_type => "text", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "active",
  { data_type => "integer", is_nullable => 0, size => undef },
  "errormsg",
  { data_type => "text", is_nullable => 0, size => undef },
  "firstevaltime",
  { data_type => "integer", is_nullable => 0, size => undef },
  "lastevaltime",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "jobset", "name");
__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  {
    "foreign.job"     => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
);
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-13 13:33:20
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:wJFyUvUACQHpaW/ktaYtOQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
