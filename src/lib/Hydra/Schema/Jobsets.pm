use utf8;
package Hydra::Schema::Jobsets;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Jobsets

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<Jobsets>

=cut

__PACKAGE__->table("Jobsets");

=head1 ACCESSORS

=head2 name

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 nixexprinput

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 nixexprpath

  data_type: 'text'
  is_nullable: 0

=head2 errormsg

  data_type: 'text'
  is_nullable: 1

=head2 errortime

  data_type: 'integer'
  is_nullable: 1

=head2 lastcheckedtime

  data_type: 'integer'
  is_nullable: 1

=head2 triggertime

  data_type: 'integer'
  is_nullable: 1

=head2 enabled

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 enableemail

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 hidden

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 emailoverride

  data_type: 'text'
  is_nullable: 0

=head2 keepnr

  data_type: 'integer'
  default_value: 3
  is_nullable: 0

=head2 checkinterval

  data_type: 'integer'
  default_value: 300
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "nixexprinput",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "nixexprpath",
  { data_type => "text", is_nullable => 0 },
  "errormsg",
  { data_type => "text", is_nullable => 1 },
  "errortime",
  { data_type => "integer", is_nullable => 1 },
  "lastcheckedtime",
  { data_type => "integer", is_nullable => 1 },
  "triggertime",
  { data_type => "integer", is_nullable => 1 },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "enableemail",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "hidden",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "emailoverride",
  { data_type => "text", is_nullable => 0 },
  "keepnr",
  { data_type => "integer", default_value => 3, is_nullable => 0 },
  "checkinterval",
  { data_type => "integer", default_value => 300, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("project", "name");

=head1 RELATIONS

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobs

Type: has_many

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobsetevals

Type: has_many

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobsetevals",
  "Hydra::Schema::JobsetEvals",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobsetinput

Type: belongs_to

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->belongs_to(
  "jobsetinput",
  "Hydra::Schema::JobsetInputs",
  { jobset => "name", name => "nixexprinput", project => "project" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 jobsetinputs

Type: has_many

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->has_many(
  "jobsetinputs",
  "Hydra::Schema::JobsetInputs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Hydra::Schema::Projects",
  { name => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-05-02 14:50:55
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:q4amPCWRoWMThnRa/n/y1w

1;
