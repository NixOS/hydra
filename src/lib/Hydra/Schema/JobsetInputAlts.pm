package Hydra::Schema::JobsetInputAlts;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("JobsetInputAlts");
__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "input",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "altnr",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "value",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "revision",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "tag",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("project", "jobset", "input", "altnr");
__PACKAGE__->belongs_to(
  "jobsetinput",
  "Hydra::Schema::JobsetInputs",
  { jobset => "jobset", name => "input", project => "project" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-02 15:59:19
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:CQg509K7bBReX30DeMC7ww


# You can replace this text with custom content, and it will be preserved on regeneration
1;
