use utf8;
package Hydra::Schema::BuildResultInfo;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildResultInfo

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildResultInfo>

=cut

__PACKAGE__->table("BuildResultInfo");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_foreign_key: 1
  is_nullable: 0

=head2 iscachedbuild

  data_type: 'integer'
  is_nullable: 0

=head2 buildstatus

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

=head2 logfile

  data_type: 'text'
  is_nullable: 1

=head2 logsize

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=head2 size

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=head2 closuresize

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=head2 releasename

  data_type: 'text'
  is_nullable: 1

=head2 keep

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 faileddepbuild

  data_type: 'integer'
  is_nullable: 1

=head2 faileddepstepnr

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_foreign_key    => 1,
    is_nullable       => 0,
  },
  "iscachedbuild",
  { data_type => "integer", is_nullable => 0 },
  "buildstatus",
  { data_type => "integer", is_nullable => 1 },
  "errormsg",
  { data_type => "text", is_nullable => 1 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
  "stoptime",
  { data_type => "integer", is_nullable => 1 },
  "logfile",
  { data_type => "text", is_nullable => 1 },
  "logsize",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
  "size",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
  "closuresize",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
  "releasename",
  { data_type => "text", is_nullable => 1 },
  "keep",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "faileddepbuild",
  { data_type => "integer", is_nullable => 1 },
  "faileddepstepnr",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 id

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" }, {});


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hX3+iQYrGslQqY9vKvyw3g

__PACKAGE__->belongs_to(
  "failedDep",
  "Hydra::Schema::BuildSteps",
  { build => "faileddepbuild", stepnr => "faileddepstepnr" },
);

1;
