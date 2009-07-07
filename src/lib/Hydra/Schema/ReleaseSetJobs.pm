package Hydra::Schema::ReleaseSetJobs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("ReleaseSetJobs");
__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "release_",
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
  "mayfail",
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
);
__PACKAGE__->set_primary_key("project", "release_", "job", "attrs");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "releaseset",
  "Hydra::Schema::ReleaseSets",
  { name => "release_", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-07-07 14:36:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:xaWTZqtzPyMq/xqi0ZFCDg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
