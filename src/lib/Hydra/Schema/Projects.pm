package Hydra::Schema::Projects;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

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
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "views",
  "Hydra::Schema::Views",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "viewjobs",
  "Hydra::Schema::ViewJobs",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "releases",
  "Hydra::Schema::Releases",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "jobsetinputhashes",
  "Hydra::Schema::JobsetInputHashes",
  { "foreign.project" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_09 @ 2009-11-17 16:05:10
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:+HDJ8tIPcvj5+IwgHqTnaw

__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  { "foreign.project" => "self.name" },
  { order_by => "name" },
);

# You can replace this text with custom content, and it will be preserved on regeneration
1;
