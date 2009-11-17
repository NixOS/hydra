package Hydra::Schema::ViewJobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("ViewJobs");
__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "view_",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "job",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "attrs",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "isprimary",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "autorelease",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "view_", "job", "attrs");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "view",
  "Hydra::Schema::Views",
  { name => "view_", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_09 @ 2009-11-17 16:04:13
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:RX9tEuV8mEg13dxEe9SJrQ


# You can replace this text with custom content, and it will be preserved on regeneration
1;
