package HydraFrontend::Schema::Jobs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("jobs");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "timestamp",
  { data_type => "integer", is_nullable => 0, size => undef },
  "priority",
  { data_type => "integer", is_nullable => 0, size => undef },
  "busy",
  { data_type => "integer", is_nullable => 0, size => undef },
  "locker",
  { data_type => "text", is_nullable => 0, size => undef },
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "jobset",
  { data_type => "text", is_nullable => 0, size => undef },
  "attrname",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "system",
  { data_type => "text", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to(
  "project",
  "HydraFrontend::Schema::Projects",
  { name => "project" },
);
__PACKAGE__->belongs_to(
  "jobset",
  "HydraFrontend::Schema::Jobsets",
  { name => "jobset", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-11-10 14:25:07
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ZF8UB1MtbPuOk7wTSFJR5Q

__PACKAGE__->has_many(
  "inputs",
  "HydraFrontend::Schema::Inputs",
  { "foreign.job" => "self.id" },
);

1;
