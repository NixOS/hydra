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

=head1 TABLE: C<Builds>

=cut

__PACKAGE__->table("Builds");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

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

=head2 nixname

  data_type: 'text'
  is_nullable: 1

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 drvpath

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

=head2 ischannel

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 iscurrent

  data_type: 'integer'
  default_value: 0
  is_nullable: 1

=head2 nixexprinput

  data_type: 'text'
  is_nullable: 1

=head2 nixexprpath

  data_type: 'text'
  is_nullable: 1

=head2 priority

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 globalpriority

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 starttime

  data_type: 'integer'
  is_nullable: 1

=head2 stoptime

  data_type: 'integer'
  is_nullable: 1

=head2 iscachedbuild

  data_type: 'integer'
  is_nullable: 1

=head2 buildstatus

  data_type: 'integer'
  is_nullable: 1

=head2 size

  data_type: 'bigint'
  is_nullable: 1

=head2 closuresize

  data_type: 'bigint'
  is_nullable: 1

=head2 releasename

  data_type: 'text'
  is_nullable: 1

=head2 keep

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 notificationpendingsince

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
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
  "nixname",
  { data_type => "text", is_nullable => 1 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "drvpath",
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
  "ischannel",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "iscurrent",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "nixexprinput",
  { data_type => "text", is_nullable => 1 },
  "nixexprpath",
  { data_type => "text", is_nullable => 1 },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "globalpriority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
  "stoptime",
  { data_type => "integer", is_nullable => 1 },
  "iscachedbuild",
  { data_type => "integer", is_nullable => 1 },
  "buildstatus",
  { data_type => "integer", is_nullable => 1 },
  "size",
  { data_type => "bigint", is_nullable => 1 },
  "closuresize",
  { data_type => "bigint", is_nullable => 1 },
  "releasename",
  { data_type => "text", is_nullable => 1 },
  "keep",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "notificationpendingsince",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 aggregateconstituents_aggregates

Type: has_many

Related object: L<Hydra::Schema::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregateconstituents_aggregates",
  "Hydra::Schema::AggregateConstituents",
  { "foreign.aggregate" => "self.id" },
  undef,
);

=head2 aggregateconstituents_constituents

Type: has_many

Related object: L<Hydra::Schema::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregateconstituents_constituents",
  "Hydra::Schema::AggregateConstituents",
  { "foreign.constituent" => "self.id" },
  undef,
);

=head2 buildinputs_builds

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildinputs_dependencies

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 buildmetrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::BuildMetrics",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildoutputs

Type: has_many

Related object: L<Hydra::Schema::BuildOutputs>

=cut

__PACKAGE__->has_many(
  "buildoutputs",
  "Hydra::Schema::BuildOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildproducts

Type: has_many

Related object: L<Hydra::Schema::BuildProducts>

=cut

__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::BuildProducts",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildstepoutputs

Type: has_many

Related object: L<Hydra::Schema::BuildStepOutputs>

=cut

__PACKAGE__->has_many(
  "buildstepoutputs",
  "Hydra::Schema::BuildStepOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildsteps

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::BuildSteps",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildsteps_propagatedfroms

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps_propagatedfroms",
  "Hydra::Schema::BuildSteps",
  { "foreign.propagatedfrom" => "self.id" },
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

=head2 jobsetevalinputs

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobsetevalinputs",
  "Hydra::Schema::JobsetEvalInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
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

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 aggregates

Type: many_to_many

Composing rels: L</aggregateconstituents_constituents> -> aggregate

=cut

__PACKAGE__->many_to_many(
  "aggregates",
  "aggregateconstituents_constituents",
  "aggregate",
);

=head2 constituents

Type: many_to_many

Composing rels: L</aggregateconstituents_aggregates> -> constituent

=cut

__PACKAGE__->many_to_many(
  "constituents",
  "aggregateconstituents_aggregates",
  "constituent",
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-08-19 16:12:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:VjYbAQwv4THW2VfWQ5ajYQ

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
  { 'foreign.drvpath' => 'self.drvpath'
  , 'foreign.build' => 'self.id'
  },
);

__PACKAGE__->many_to_many("jobsetevals", "jobsetevalmembers", "eval");

__PACKAGE__->many_to_many("constituents_", "aggregateconstituents_aggregates", "constituent");

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

    my $activeJobs = "(select distinct project, jobset, job, system from Builds where isCurrent = 1 $constraint)";

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
                  and finished = 1 and buildstatus = 0
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
        'starttime',
        'stoptime',
        'project',
        'jobset',
        'job',
        'nixname',
        'system',
        'priority',
        'buildstatus',
        'releasename',
        'drvpath',
    ],
    relations => {
        jobsetevals => 'id'
    },
    eager_relations => {
        buildoutputs => 'name',
        buildproducts => 'productnr',
        buildmetrics => 'name',
    }
);

sub json_hint {
    return \%hint;
}

1;
