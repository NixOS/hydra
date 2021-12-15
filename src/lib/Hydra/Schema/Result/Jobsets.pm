use utf8;
package Hydra::Schema::Result::Jobsets;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::Jobsets

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

=head2 enable_dynamic_run_command

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

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
  "enable_dynamic_run_command",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
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

Related object: L<Hydra::Schema::Result::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::Result::BuildMetrics",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Result::Builds",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

=head2 jobsetevals

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobsetevals",
  "Hydra::Schema::Result::JobsetEvals",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

=head2 jobsetinputs

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetInputs>

=cut

__PACKAGE__->has_many(
  "jobsetinputs",
  "Hydra::Schema::Result::JobsetInputs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobsetrenames

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetRenames>

=cut

__PACKAGE__->has_many(
  "jobsetrenames",
  "Hydra::Schema::Result::JobsetRenames",
  { "foreign.project" => "self.project", "foreign.to_" => "self.name" },
  undef,
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Result::Projects>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Hydra::Schema::Result::Projects",
  { name => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::Result::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::Result::StarredJobs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-01-24 14:17:33
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:7wPE5ebeVTkenMCWG9Sgcg

use JSON::MaybeXS;

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Result::Builds",
  { "foreign.jobset_id" => "self.id" },
  undef,
);

__PACKAGE__->add_column(
    "+id" => { retrieve_on_insert => 1 }
);

sub as_json {
    my $self = shift;

    my %json = (
        # columns
        "errortime" => $self->get_column("errortime"),
        "lastcheckedtime" => $self->get_column("lastcheckedtime"),
        "triggertime" => $self->get_column("triggertime"),
        "enabled" => $self->get_column("enabled"),
        "keepnr" => $self->get_column("keepnr"),
        "checkinterval" => $self->get_column("checkinterval"),
        "schedulingshares" => $self->get_column("schedulingshares"),
        "starttime" => $self->get_column("starttime"),

        # string_columns
        "name" => $self->get_column("name") // "",
        "project" => $self->get_column("project") // "",
        "description" => $self->get_column("description") // "",
        "nixexprinput" => $self->get_column("nixexprinput") // "",
        "nixexprpath" => $self->get_column("nixexprpath") // "",
        "errormsg" => $self->get_column("errormsg") // "",
        "emailoverride" => $self->get_column("emailoverride") // "",
        "fetcherrormsg" => $self->get_column("fetcherrormsg") // "",
        "type" => $self->get_column("type") // "",
        "flake" => $self->get_column("flake") // "",

        # boolean_columns
        "enableemail" => $self->get_column("enableemail") ? JSON::MaybeXS::true : JSON::MaybeXS::false,
        "visible" => $self->get_column("hidden") ? JSON::MaybeXS::false : JSON::MaybeXS::true,

        "inputs" => { map { $_->name => $_ } $self->jobsetinputs }
    );

    return \%json;
}

1;
