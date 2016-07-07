use utf8;
package Hydra::Schema::Builds;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Builds

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

=head1 TABLE: C<builds>

=cut

__PACKAGE__->table("builds");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'builds_id_seq'

=head2 finished

  data_type: 'integer'
  is_nullable: 0

=head2 timestamp

  data_type: 'integer'
  is_nullable: 0

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 job

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 nix_name

  data_type: 'text'
  is_nullable: 1

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 drv_path

  data_type: 'text'
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 0

=head2 license

  data_type: 'text'
  is_nullable: 1

=head2 homepage

  data_type: 'text'
  is_nullable: 1

=head2 maintainers

  data_type: 'text'
  is_nullable: 1

=head2 maxsilent

  data_type: 'integer'
  default_value: 3600
  is_nullable: 1

=head2 timeout

  data_type: 'integer'
  default_value: 36000
  is_nullable: 1

=head2 is_channel

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 is_current

  data_type: 'integer'
  default_value: 0
  is_nullable: 1

=head2 nix_expr_input

  data_type: 'text'
  is_nullable: 1

=head2 nix_expr_path

  data_type: 'text'
  is_nullable: 1

=head2 priority

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 global_priority

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 start_time

  data_type: 'integer'
  is_nullable: 1

=head2 stop_time

  data_type: 'integer'
  is_nullable: 1

=head2 is_cached_build

  data_type: 'integer'
  is_nullable: 1

=head2 build_status

  data_type: 'integer'
  is_nullable: 1

=head2 size

  data_type: 'bigint'
  is_nullable: 1

=head2 closure_size

  data_type: 'bigint'
  is_nullable: 1

=head2 release_name

  data_type: 'text'
  is_nullable: 1

=head2 keep

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "builds_id_seq",
  },
  "finished",
  { data_type => "integer", is_nullable => 0 },
  "timestamp",
  { data_type => "integer", is_nullable => 0 },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "job",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "nix_name",
  { data_type => "text", is_nullable => 1 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "drv_path",
  { data_type => "text", is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 0 },
  "license",
  { data_type => "text", is_nullable => 1 },
  "homepage",
  { data_type => "text", is_nullable => 1 },
  "maintainers",
  { data_type => "text", is_nullable => 1 },
  "maxsilent",
  { data_type => "integer", default_value => 3600, is_nullable => 1 },
  "timeout",
  { data_type => "integer", default_value => 36000, is_nullable => 1 },
  "is_channel",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "is_current",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "nix_expr_input",
  { data_type => "text", is_nullable => 1 },
  "nix_expr_path",
  { data_type => "text", is_nullable => 1 },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "global_priority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "start_time",
  { data_type => "integer", is_nullable => 1 },
  "stop_time",
  { data_type => "integer", is_nullable => 1 },
  "is_cached_build",
  { data_type => "integer", is_nullable => 1 },
  "build_status",
  { data_type => "integer", is_nullable => 1 },
  "size",
  { data_type => "bigint", is_nullable => 1 },
  "closure_size",
  { data_type => "bigint", is_nullable => 1 },
  "release_name",
  { data_type => "text", is_nullable => 1 },
  "keep",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 aggregate_constituents_aggregates

Type: has_many

Related object: L<Hydra::Schema::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregate_constituents_aggregates",
  "Hydra::Schema::AggregateConstituents",
  { "foreign.aggregate" => "self.id" },
  undef,
);

=head2 aggregate_constituents_constituents

Type: has_many

Related object: L<Hydra::Schema::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregate_constituents_constituents",
  "Hydra::Schema::AggregateConstituents",
  { "foreign.constituent" => "self.id" },
  undef,
);

=head2 build_inputs_builds

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "build_inputs_builds",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_inputs_dependencies

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "build_inputs_dependencies",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 build_metrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "build_metrics",
  "Hydra::Schema::BuildMetrics",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_outputs

Type: has_many

Related object: L<Hydra::Schema::BuildOutputs>

=cut

__PACKAGE__->has_many(
  "build_outputs",
  "Hydra::Schema::BuildOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_products

Type: has_many

Related object: L<Hydra::Schema::BuildProducts>

=cut

__PACKAGE__->has_many(
  "build_products",
  "Hydra::Schema::BuildProducts",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_step_outputs

Type: has_many

Related object: L<Hydra::Schema::BuildStepOutputs>

=cut

__PACKAGE__->has_many(
  "build_step_outputs",
  "Hydra::Schema::BuildStepOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_steps

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "build_steps",
  "Hydra::Schema::BuildSteps",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 build_steps_propagated_froms

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "build_steps_propagated_froms",
  "Hydra::Schema::BuildSteps",
  { "foreign.propagated_from" => "self.id" },
  undef,
);

=head2 job

Type: belongs_to

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->belongs_to(
  "job",
  "Hydra::Schema::Jobs",
  { jobset => "jobset", name => "job", project => "project" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "CASCADE" },
);

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "CASCADE" },
);

=head2 jobset_eval_inputs

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobset_eval_inputs",
  "Hydra::Schema::JobsetEvalInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 jobset_eval_members

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobset_eval_members",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.build" => "self.id" },
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
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "CASCADE" },
);

=head2 release_members

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "release_members",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 aggregates

Type: many_to_many

Composing rels: L</aggregate_constituents_constituents> -> aggregate

=cut

__PACKAGE__->many_to_many(
  "aggregates",
  "aggregate_constituents_constituents",
  "aggregate",
);

=head2 constituents

Type: many_to_many

Composing rels: L</aggregate_constituents_aggregates> -> constituent

=cut

__PACKAGE__->many_to_many(
  "constituents",
  "aggregate_constituents_aggregates",
  "constituent",
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:QDUGB7t90kx7Q4U7HE6bSw

__PACKAGE__->has_many(
  "dependents",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
);

__PACKAGE__->many_to_many(dependentBuilds => 'dependents', 'build');

__PACKAGE__->has_many(
  "inputs",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
);

__PACKAGE__->has_one(
  "actualBuildStep",
  "Hydra::Schema::BuildSteps",
  { 'foreign.drv_path' => 'self.drv_path'
  , 'foreign.build' => 'self.id'
  },
);

__PACKAGE__->many_to_many("jobset_evals", "jobset_eval_members", "eval");

__PACKAGE__->many_to_many("constituents_", "aggregate_constituents_aggregates", "constituent");

sub makeSource {
    my ($name, $query) = @_;
    my $source = __PACKAGE__->result_source_instance();
    my $new_source = $source->new($source);
    $new_source->source_name($name);
    $new_source->name(\ "($query)");
    Hydra::Schema->register_extra_source($name => $new_source);
}

sub makeQueries {
    my ($name, $constraint) = @_;

    my $activeJobs = "(select distinct project, jobset, job, system from Builds where is_current = 1 $constraint)";

    makeSource(
        "LatestSucceeded$name",
        <<QUERY
          select *
          from
            (select
               (select max(b.id) from builds b
                where
                  project = activeJobs.project and jobset = activeJobs.jobset
                  and job = activeJobs.job and system = activeJobs.system
                  and finished = 1 and build_status = 0
               ) as id
             from $activeJobs as activeJobs
            ) as latest
          join Builds using (id)
QUERY
    );
}

makeQueries('', "");
makeQueries('ForProject', "and project = ?");
makeQueries('ForJobset', "and project = ? and jobset = ?");
makeQueries('ForJob', "and project = ? and jobset = ? and job = ?");


my %hint = (
    columns => [
        'id',
        'finished',
        'timestamp',
        'start_time',
        'stop_time',
        'project',
        'jobset',
        'job',
        'nix_name',
        'system',
        'priority',
        'build_status',
        'release_name'
    ],
    relations => {
        jobset_evals => 'id'
    },
    eager_relations => {
        build_outputs => 'name',
        build_products => 'productnr',
        build_metrics => 'name',
    }
);

sub json_hint {
    return \%hint;
}

1;
