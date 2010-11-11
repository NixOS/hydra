package Hydra::Schema::BuildResultInfo;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildResultInfo

=cut

__PACKAGE__->table("BuildResultInfo");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 iscachedbuild

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 buildstatus

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 errormsg

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 starttime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 stoptime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 logfile

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 logsize

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 size

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 closuresize

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 releasename

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 keep

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 faileddepbuild

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 faileddepstepnr

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=cut

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
  "logsize",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "size",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "closuresize",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
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

=head1 RELATIONS

=head2 id

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" }, {});


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-11-11 10:58:44
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:7RntgXzDYpnfVLfja5RXKg

__PACKAGE__->belongs_to(
  "failedDep",
  "Hydra::Schema::BuildSteps",
  { build => "faileddepbuild", stepnr => "faileddepstepnr" },
);

1;
