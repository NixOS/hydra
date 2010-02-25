package Hydra::Schema::Builds;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Builds

=cut

__PACKAGE__->table("Builds");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_auto_increment: 1
  is_nullable: 0
  size: undef

=head2 finished

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 timestamp

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 project

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 jobset

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 job

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 nixname

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 drvpath

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 outpath

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 system

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 longdescription

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 license

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 homepage

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 maintainers

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 iscurrent

  data_type: integer
  default_value: 0
  is_nullable: 1
  size: undef

=head2 nixexprinput

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 nixexprpath

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_auto_increment => 1,
    is_nullable => 0,
    size => undef,
  },
  "finished",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "timestamp",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "job",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "nixname",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "drvpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "outpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "system",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "longdescription",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "license",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "homepage",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "maintainers",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "iscurrent",
  { data_type => "integer", default_value => 0, is_nullable => 1, size => undef },
  "nixexprinput",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "nixexprpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
  {},
);

=head2 job

Type: belongs_to

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->belongs_to(
  "job",
  "Hydra::Schema::Jobs",
  { jobset => "jobset", name => "job", project => "project" },
  {},
);

=head2 buildschedulinginfo

Type: might_have

Related object: L<Hydra::Schema::BuildSchedulingInfo>

=cut

__PACKAGE__->might_have(
  "buildschedulinginfo",
  "Hydra::Schema::BuildSchedulingInfo",
  { "foreign.id" => "self.id" },
);

=head2 buildresultinfo

Type: might_have

Related object: L<Hydra::Schema::BuildResultInfo>

=cut

__PACKAGE__->might_have(
  "buildresultinfo",
  "Hydra::Schema::BuildResultInfo",
  { "foreign.id" => "self.id" },
);

=head2 buildsteps

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::BuildSteps",
  { "foreign.build" => "self.id" },
);

=head2 buildinputs_builds

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
);

=head2 buildinputs_dependencies

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
);

=head2 buildproducts

Type: has_many

Related object: L<Hydra::Schema::BuildProducts>

=cut

__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::BuildProducts",
  { "foreign.build" => "self.id" },
);

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.build" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:dsXIx+mh+etSD7zKQJ6I3A

use Hydra::Helper::Nix;

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

__PACKAGE__->belongs_to(
  "schedulingInfo",
  "Hydra::Schema::BuildSchedulingInfo",
  { id => "id" },
);

__PACKAGE__->belongs_to(
  "resultInfo",
  "Hydra::Schema::BuildResultInfo",
  { id => "id" },
);

sub addSequence {
    my $hydradbi = getHydraDBPath;
    if ($hydradbi =~ m/^dbi:Pg/) {
        __PACKAGE__->sequence('builds_id_seq');
    }
}

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
    
    my $joinWithStatusChange =
        <<QUERY;
          natural join BuildResultInfo r
          left join Builds b on
            b.id =
              (select max(id)
               from builds c natural join buildresultinfo r2
               where
                 x.project = c.project and x.jobset = c.jobset and x.job = c.job and x.system = c.system and
                 x.id > c.id and
                   ((r.buildstatus = 0 and r2.buildstatus != 0) or
                    (r.buildstatus != 0 and r2.buildstatus = 0)))
QUERY

    my $activeJobs = "(select distinct project, jobset, job, system from Builds where isCurrent = 1 $constraint)";

    makeSource(
        "JobStatus$name",
        # Urgh, can't use "*" in the "select" here because of the status change join.
        <<QUERY
          select 
            x.id, x.finished, x.timestamp, x.project, x.jobset, x.job, x.nixname,
            x.description, x.drvpath, x.outpath, x.system, x.longdescription,
            x.license, x.homepage, x.maintainers, x.isCurrent, x.nixExprInput,
            x.nixExprPath,
            b.id as statusChangeId, b.timestamp as statusChangeTime
          from
            (select project, jobset, job, system, max(id) as id
             from $activeJobs as activeJobs
             natural join Builds
             where finished = 1
             group by project, jobset, job, system)
            as latest
          natural join Builds x
          $joinWithStatusChange
QUERY
    );
    
    makeSource(
        "LatestSucceeded$name",
        <<QUERY
          select *
          from
            (select project, jobset, job, system, max(id) as id
             from $activeJobs as activeJobs
             natural join Builds
             natural join BuildResultInfo
             where finished = 1 and buildStatus = 0
             group by project, jobset, job, system
            ) as latest
          natural join Builds
QUERY
    );
}

addSequence;

makeQueries('', "");
makeQueries('ForProject', "and project = ?");
makeQueries('ForJobset', "and project = ? and jobset = ?");
makeQueries('ForJob', "and project = ? and jobset = ? and job = ?");

1;
