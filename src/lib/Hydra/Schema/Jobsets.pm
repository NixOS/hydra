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

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<jobsets>

=cut

__PACKAGE__->table("jobsets");

=head1 ACCESSORS

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobsets_id_seq'

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 nixexprinput

  data_type: 'text'
  is_nullable: 1

=head2 nixexprpath

  data_type: 'text'
  is_nullable: 1

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

=head2 schedulingshares

  data_type: 'integer'
  default_value: 100
  is_nullable: 0

=head2 fetcherrormsg

  data_type: 'text'
  is_nullable: 1

=head2 forceeval

  data_type: 'boolean'
  is_nullable: 1

=head2 starttime

  data_type: 'integer'
  is_nullable: 1

=head2 type

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 flake

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0 },
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "jobsets_id_seq",
  },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "nixexprinput",
  { data_type => "text", is_nullable => 1 },
  "nixexprpath",
  { data_type => "text", is_nullable => 1 },
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
  "schedulingshares",
  { data_type => "integer", default_value => 100, is_nullable => 0 },
  "fetcherrormsg",
  { data_type => "text", is_nullable => 1 },
  "forceeval",
  { data_type => "boolean", is_nullable => 1 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
  "type",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "flake",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("project", "name");

=head1 UNIQUE CONSTRAINTS

=head2 C<jobsets_id_unique>

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->add_unique_constraint("jobsets_id_unique", ["id"]);

=head1 RELATIONS

=head2 buildmetrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::BuildMetrics",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 builds_jobset_ids

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds_jobset_ids",
  "Hydra::Schema::Builds",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

=head2 builds_project_jobsets

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds_project_jobsets",
  "Hydra::Schema::Builds",
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

=head2 jobsetrenames

Type: has_many

Related object: L<Hydra::Schema::JobsetRenames>

=cut

__PACKAGE__->has_many(
  "jobsetrenames",
  "Hydra::Schema::JobsetRenames",
  { "foreign.project" => "self.project", "foreign.to_" => "self.name" },
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

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::StarredJobs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-01-22 07:11:57
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:6P1qlC5oVSPRSgRBp6nmrw


=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

=head2 jobs

Type: has_many

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

__PACKAGE__->add_column(
    "+id" => { retrieve_on_insert => 1 }
);

my %hint = (
    columns => [
        "enabled",
        "errormsg",
        "fetcherrormsg",
        "emailoverride",
        "nixexprpath",
        "nixexprinput"
    ],
    eager_relations => {
        jobsetinputs => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
