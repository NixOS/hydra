package Hydra::Schema::BuildResultInfo;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildResultInfo");
__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "iscachedbuild",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "buildstatus",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "errormsg",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "starttime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "stoptime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "logfile",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "releasename",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "keep",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "faileddepbuild",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "faileddepstepnr",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" });


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-02 15:59:19
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:L/qLimgzcHeLjsKom3t1XQ

__PACKAGE__->belongs_to(
  "failedDep",
  "Hydra::Schema::BuildSteps",
  { build => "faileddepbuild", stepnr => "faileddepstepnr" },
);

1;
