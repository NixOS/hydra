use utf8;
package Hydra::Schema::BuildSteps;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildSteps

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildSteps>

=cut

__PACKAGE__->table("BuildSteps");

=head1 ACCESSORS

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 stepnr

  data_type: 'integer'
  is_nullable: 0

=head2 type

  data_type: 'integer'
  is_nullable: 0

=head2 drvpath

  data_type: 'text'
  is_nullable: 1

=head2 outpath

  data_type: 'text'
  is_nullable: 1

=head2 logfile

  data_type: 'text'
  is_nullable: 1

=head2 busy

  data_type: 'integer'
  is_nullable: 0

=head2 status

  data_type: 'integer'
  is_nullable: 1

=head2 errormsg

  data_type: 'text'
  is_nullable: 1

=head2 starttime

  data_type: 'integer'
  is_nullable: 1

=head2 stoptime

  data_type: 'integer'
  is_nullable: 1

=head2 machine

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "stepnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "integer", is_nullable => 0 },
  "drvpath",
  { data_type => "text", is_nullable => 1 },
  "outpath",
  { data_type => "text", is_nullable => 1 },
  "logfile",
  { data_type => "text", is_nullable => 1 },
  "busy",
  { data_type => "integer", is_nullable => 0 },
  "status",
  { data_type => "integer", is_nullable => 1 },
  "errormsg",
  { data_type => "text", is_nullable => 1 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
  "stoptime",
  { data_type => "integer", is_nullable => 1 },
  "machine",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</build>

=item * L</stepnr>

=back

=cut

__PACKAGE__->set_primary_key("build", "stepnr");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" }, {});


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:5H+OkGT0zQEWkAjU+OlBdg

__PACKAGE__->belongs_to(
  "schedulingInfo",
  "Hydra::Schema::BuildSchedulingInfo",
  { id => "build" },
);

1;
