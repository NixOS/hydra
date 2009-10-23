package Hydra::Schema::Releases;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Releases");
__PACKAGE__->add_columns(
  "project",
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
  "timestamp",
  {
    data_type => "integer",
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
);
__PACKAGE__->set_primary_key("project", "name");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  {
    "foreign.project"  => "self.project",
    "foreign.release_" => "self.name",
  },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-21 17:40:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:udsx/5Ic4ul6vDoR6IwFAg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
