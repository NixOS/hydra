package Hydra::Schema::BuildSteps;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildSteps

=cut

__PACKAGE__->table("BuildSteps");

=head1 ACCESSORS

=head2 build

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 stepnr

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 type

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 drvpath

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 outpath

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 logfile

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 busy

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 status

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

=head2 machine

  data_type: text
  default_value: ''
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "build",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "stepnr",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "type",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "drvpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "outpath",
  {
    data_type => "text",
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
  "busy",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "status",
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
  "machine",
  { data_type => "text", default_value => "''", is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("build", "stepnr");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" }, {});


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-08-31 15:40:29
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:CC/XBHMiRLuQSI+nEFW50g

1;
