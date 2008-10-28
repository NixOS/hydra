package HydraFrontend::Schema::Builds;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("builds");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "timestamp",
  { data_type => "integer", is_nullable => 0, size => undef },
  "name",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "buildstatus",
  { data_type => "integer", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->has_many(
  "buildlogs",
  "HydraFrontend::Schema::Buildlogs",
  { "foreign.buildid" => "self.id" },
);
__PACKAGE__->has_many(
  "buildproducts",
  "HydraFrontend::Schema::Buildproducts",
  { "foreign.buildid" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2008-10-25 22:23:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gxVH+2KWcgU41JOl9BbHFA

1;
