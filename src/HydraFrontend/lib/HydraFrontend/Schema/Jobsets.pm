package HydraFrontend::Schema::Jobsets;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Jobsets");
__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "nixexprinput",
  { data_type => "text", is_nullable => 0, size => undef },
  "nixexprpath",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "name");
__PACKAGE__->has_many(
  "builds",
  "HydraFrontend::Schema::Builds",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
);
__PACKAGE__->belongs_to(
  "project",
  "HydraFrontend::Schema::Projects",
  { name => "project" },
);
__PACKAGE__->belongs_to(
  "jobsetinput",
  "HydraFrontend::Schema::Jobsetinputs",
  { job => "name", name => "nixexprinput", project => "project" },
);
__PACKAGE__->has_many(
  "jobsetinputs",
  "HydraFrontend::Schema::Jobsetinputs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-12 17:11:42
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Ed14Jg43pSHx6rNdYW6kLg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
