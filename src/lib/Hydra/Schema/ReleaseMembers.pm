package Hydra::Schema::ReleaseMembers;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("ReleaseMembers");
__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "release_",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "build",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
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
);
__PACKAGE__->set_primary_key("project", "release_", "build");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "release",
  "Hydra::Schema::Releases",
  { name => "release_", project => "project" },
);
__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" });


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-21 17:40:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:wBLLjLvDq9RWmybMfJiDtQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
