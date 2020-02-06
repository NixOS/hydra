use utf8;
package Hydra::Schema::Jobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Jobs

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

=head1 TABLE: C<jobs>

=cut

__PACKAGE__->table("jobs");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</jobset>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("project", "jobset", "name");

=head1 RELATIONS

=head2 buildmetrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::BuildMetrics",
  {
    "foreign.job"     => "self.name",
    "foreign.jobset"  => "self.jobset",
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
    "foreign.job"     => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
  undef,
);

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { id => "jobset_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 jobset_project_jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset_project_jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
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
    "foreign.job"     => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-02-06 12:33:28
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:C5Tyh8Ke4yC6q7KIFVOHcQ

=head2 builds

Type: has_many

Related object: L<Hydra::Sc2hema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  {
    "foreign.job"     => "self.name",
    "foreign.jobset_id"  => "self.jobset_id",
  },
  undef,
);

1;
