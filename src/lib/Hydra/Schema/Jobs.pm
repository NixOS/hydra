package Hydra::Schema::Jobs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Jobs");
__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "active",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "errormsg",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "firstevaltime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "lastevaltime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "jobset", "name");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
);
__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  {
    "foreign.job"     => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-21 14:17:55
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:AjrYM1rAdgYy3j0+IFFUEw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
