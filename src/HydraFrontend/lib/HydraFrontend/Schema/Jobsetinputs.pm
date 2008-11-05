package HydraFrontend::Schema::Jobsetinputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("jobSetInputs");
__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "job",
  { data_type => "text", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
  "uri",
  { data_type => "text", is_nullable => 0, size => undef },
  "revision",
  { data_type => "integer", is_nullable => 0, size => undef },
  "tag",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "job", "name");
__PACKAGE__->has_many(
  "jobsets",
  "HydraFrontend::Schema::Jobsets",
  {
    "foreign.name"         => "self.job",
    "foreign.nixexprinput" => "self.name",
    "foreign.project"      => "self.project",
  },
);
__PACKAGE__->belongs_to(
  "jobset",
  "HydraFrontend::Schema::Jobsets",
  { name => "job", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-05 23:48:14
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:fKqDK1YOZXl88jxNRwEvSA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
