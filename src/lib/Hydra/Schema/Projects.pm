package Hydra::Schema::Projects;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Projects");
__PACKAGE__->add_columns(
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "displayname",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "owner",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "homepage",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("name");
__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->belongs_to("owner", "Hydra::Schema::Users", { username => "owner" });
__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "releasesets",
  "Hydra::Schema::ReleaseSets",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "releasesetjobs",
  "Hydra::Schema::ReleaseSetJobs",
  { "foreign.project" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-08 13:25:04
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Dru36PNUe9iYHEwhhHKJ3A


# You can replace this text with custom content, and it will be preserved on regeneration
1;
