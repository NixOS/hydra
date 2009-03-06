package Hydra::Schema::JobsetInputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("JobsetInputs");
__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "jobset",
  { data_type => "text", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "type",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "jobset", "name");
__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  {
    "foreign.name"         => "self.job",
    "foreign.nixexprinput" => "self.name",
    "foreign.project"      => "self.project",
  },
);
__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
);
__PACKAGE__->has_many(
  "jobsetinputalts",
  "Hydra::Schema::JobsetInputAlts",
  {
    "foreign.input"   => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-06 14:20:12
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:TUTdwfhSsFMKBXa/wKenOQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
