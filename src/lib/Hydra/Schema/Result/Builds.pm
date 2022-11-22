use utf8;
package Hydra::Schema::Result::Builds;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::Builds

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

=head2 jobset_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 job

  data_type: 'text'
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
  "jobset_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "job",
  { data_type => "text", is_nullable => 0 },
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

Related object: L<Hydra::Schema::Result::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregateconstituents_aggregates",
  "Hydra::Schema::Result::AggregateConstituents",
  { "foreign.aggregate" => "self.id" },
  undef,
);

=head2 aggregateconstituents_constituents

Type: has_many

Related object: L<Hydra::Schema::Result::AggregateConstituents>

=cut

__PACKAGE__->has_many(
  "aggregateconstituents_constituents",
  "Hydra::Schema::Result::AggregateConstituents",
  { "foreign.constituent" => "self.id" },
  undef,
);

=head2 buildinputs_builds

Type: has_many

Related object: L<Hydra::Schema::Result::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::Result::BuildInputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildinputs_dependencies

Type: has_many

Related object: L<Hydra::Schema::Result::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::Result::BuildInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 buildmetrics

Type: has_many

Related object: L<Hydra::Schema::Result::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::Result::BuildMetrics",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildoutputs

Type: has_many

Related object: L<Hydra::Schema::Result::BuildOutputs>

=cut

__PACKAGE__->has_many(
  "buildoutputs",
  "Hydra::Schema::Result::BuildOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildproducts

Type: has_many

Related object: L<Hydra::Schema::Result::BuildProducts>

=cut

__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::Result::BuildProducts",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildstepoutputs

Type: has_many

Related object: L<Hydra::Schema::Result::BuildStepOutputs>

=cut

__PACKAGE__->has_many(
  "buildstepoutputs",
  "Hydra::Schema::Result::BuildStepOutputs",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildsteps

Type: has_many

Related object: L<Hydra::Schema::Result::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::Result::BuildSteps",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 buildsteps_propagatedfroms

Type: has_many

Related object: L<Hydra::Schema::Result::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps_propagatedfroms",
  "Hydra::Schema::Result::BuildSteps",
  { "foreign.propagatedfrom" => "self.id" },
  undef,
);

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Result::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Result::Jobsets",
  { id => "jobset_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 jobsetevalinputs

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobsetevalinputs",
  "Hydra::Schema::Result::JobsetEvalInputs",
  { "foreign.dependency" => "self.id" },
  undef,
);

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
  "Hydra::Schema::Result::JobsetEvalMembers",
  { "foreign.build" => "self.id" },
  undef,
);

=head2 runcommandlogs

Type: has_many

Related object: L<Hydra::Schema::Result::RunCommandLogs>

=cut

__PACKAGE__->has_many(
  "runcommandlogs",
  "Hydra::Schema::Result::RunCommandLogs",
  { "foreign.build_id" => "self.id" },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-01-10 09:43:38
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:DQF8KRinnf0imJOP+lvH9Q

__PACKAGE__->has_many(
  "dependents",
  "Hydra::Schema::Result::BuildInputs",
  { "foreign.dependency" => "self.id" },
);

__PACKAGE__->many_to_many(dependentBuilds => 'dependents', 'build');

__PACKAGE__->has_many(
  "inputs",
  "Hydra::Schema::Result::BuildInputs",
  { "foreign.build" => "self.id" },
);

__PACKAGE__->has_one(
  "actualBuildStep",
  "Hydra::Schema::Result::BuildSteps",
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

    my $activeJobs = "(select distinct jobset_id, job, system from Builds where isCurrent = 1 $constraint)";

    makeSource(
        "LatestSucceeded$name",
        <<QUERY
          select *
          from
            (select
               (select max(b.id) from builds b
                where
                  jobset_id = activeJobs.jobset_id
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
makeQueries('ForProject', "and jobset_id in (select id from jobsets j where j.project = ?)");
makeQueries('ForJobset', "and jobset_id = ?");
makeQueries('ForJob', "and jobset_id = ? and job = ?");
makeQueries('ForJobName', "and jobset_id = (select id from jobsets j where j.name = ?) and job = ?");

sub as_json {
  my ($self) = @_;

  # After #1093 merges this can become $self->jobset;
  # However, with ->jobset being a column on master
  # it seems DBIX gets a it confused.
  my ($jobset) = $self->search_related('jobset')->first;

  my $json = {
    id => $self->get_column('id'),
    finished => $self->get_column('finished'),
    timestamp => $self->get_column('timestamp'),
    starttime => $self->get_column('starttime'),
    stoptime => $self->get_column('stoptime'),
    project => $jobset->get_column('project'),
    jobset => $jobset->name,
    job => $self->get_column('job'),
    nixname => $self->get_column('nixname'),
    system => $self->get_column('system'),
    priority => $self->get_column('priority'),
    buildstatus => $self->get_column('buildstatus'),
    releasename => $self->get_column('releasename'),
    drvpath => $self->get_column('drvpath'),
    jobsetevals => [ map { $_->id } $self->jobsetevals ],
    buildoutputs => { map { $_->name  => $_ } $self->buildoutputs },
    buildproducts => { map { $_->productnr => $_ } $self->buildproducts },
    buildmetrics => { map { $_->name => $_ } $self->buildmetrics },
  };

  return $json;
}

sub project {
  my ($self) = @_;
  return $self->jobset->project;
}

1;
