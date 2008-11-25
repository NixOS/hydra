package HydraFrontend::Schema::Projects;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Projects");
__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "displayname",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "enabled",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("name");
__PACKAGE__->has_many(
  "builds",
  "HydraFrontend::Schema::Builds",
  { "foreign.project" => "self.name" },
);
__PACKAGE__->has_many(
  "jobsets",
  "HydraFrontend::Schema::Jobsets",
  { "foreign.project" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-24 17:46:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:M+HA5YEL1oKKTQlLvhb6dw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
