package HydraFrontend::Schema::Projects;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("projects");
__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("name");
__PACKAGE__->has_many(
  "jobsets",
  "HydraFrontend::Schema::Jobsets",
  { "foreign.project" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-07 17:44:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:fIpNlZNqqGDGGWd6EORCAA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
