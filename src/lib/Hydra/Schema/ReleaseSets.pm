package Hydra::Schema::ReleaseSets;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("ReleaseSets");
__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "keep",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "name");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->has_many(
  "releasesetjobs",
  "Hydra::Schema::ReleaseSetJobs",
  {
    "foreign.project"  => "self.project",
    "foreign.release_" => "self.name",
  },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-12 17:44:15
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:0DtIgm5jznjy1l3809b06Q


# You can replace this text with custom content, and it will be preserved on regeneration
1;
