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

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 nix_expr_input

  data_type: 'text'
  is_nullable: 0

=head2 nix_expr_path

  data_type: 'text'
  is_nullable: 0

=head2 error_msg

  data_type: 'text'
  is_nullable: 1

=head2 error_time

  data_type: 'integer'
  is_nullable: 1

=head2 last_checked_time

  data_type: 'integer'
  is_nullable: 1

=head2 trigger_time

  data_type: 'integer'
  is_nullable: 1

=head2 enabled

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 enable_email

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 hidden

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 email_override

  data_type: 'text'
  is_nullable: 0

=head2 keepnr

  data_type: 'integer'
  default_value: 3
  is_nullable: 0

=head2 check_interval

  data_type: 'integer'
  default_value: 300
  is_nullable: 0

=head2 scheduling_shares

  data_type: 'integer'
  default_value: 100
  is_nullable: 0

=head2 fetch_error_msg

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0 },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "nix_expr_input",
  { data_type => "text", is_nullable => 0 },
  "nix_expr_path",
  { data_type => "text", is_nullable => 0 },
  "error_msg",
  { data_type => "text", is_nullable => 1 },
  "error_time",
  { data_type => "integer", is_nullable => 1 },
  "last_checked_time",
  { data_type => "integer", is_nullable => 1 },
  "trigger_time",
  { data_type => "integer", is_nullable => 1 },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "enable_email",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "hidden",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "email_override",
  { data_type => "text", is_nullable => 0 },
  "keepnr",
  { data_type => "integer", default_value => 3, is_nullable => 0 },
  "check_interval",
  { data_type => "integer", default_value => 300, is_nullable => 0 },
  "scheduling_shares",
  { data_type => "integer", default_value => 100, is_nullable => 0 },
  "fetch_error_msg",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("project", "name");

=head1 RELATIONS

=head2 build_metrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "build_metrics",
  "Hydra::Schema::BuildMetrics",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

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

=head2 jobset_evals

Type: has_many

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobset_evals",
  "Hydra::Schema::JobsetEvals",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobset_inputs

Type: has_many

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->has_many(
  "jobset_inputs",
  "Hydra::Schema::JobsetInputs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobset_renames

Type: has_many

Related object: L<Hydra::Schema::JobsetRenames>

=cut

__PACKAGE__->has_many(
  "jobset_renames",
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

=head2 starred_jobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starred_jobs",
  "Hydra::Schema::StarredJobs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:sijwV7YKe565quMZRLi2kw

my %hint = (
    columns => [
        "enabled",
        "error_msg",
        "fetch_error_msg",
        "email_override",
        "nix_expr_path",
        "nix_expr_input"
    ],
    eager_relations => {
        jobset_inputs => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
