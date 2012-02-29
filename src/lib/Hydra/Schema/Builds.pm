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

=head2 outpath

  data_type: 'text'
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 0

=head2 longdescription

  data_type: 'text'
  is_nullable: 1

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

=head2 busy

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 locker

  data_type: 'text'
  is_nullable: 1

=head2 logfile

  data_type: 'text'
  is_nullable: 1

=head2 disabled

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 starttime

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
  "outpath",
  { data_type => "text", is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 0 },
  "longdescription",
  { data_type => "text", is_nullable => 1 },
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
  "iscurrent",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "nixexprinput",
  { data_type => "text", is_nullable => 1 },
  "nixexprpath",
  { data_type => "text", is_nullable => 1 },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "busy",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "locker",
  { data_type => "text", is_nullable => 1 },
  "logfile",
  { data_type => "text", is_nullable => 1 },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 buildinputs_builds

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
  {},
);

=head2 buildinputs_dependencies

Type: has_many

Related object: L<Hydra::Schema::BuildInputs>

=cut

__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
  {},
);

=head2 buildproducts

Type: has_many

Related object: L<Hydra::Schema::BuildProducts>

=cut

__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::BuildProducts",
  { "foreign.build" => "self.id" },
  {},
);

=head2 buildresultinfo

Type: might_have

Related object: L<Hydra::Schema::BuildResultInfo>

=cut

__PACKAGE__->might_have(
  "buildresultinfo",
  "Hydra::Schema::BuildResultInfo",
  { "foreign.id" => "self.id" },
  {},
);

=head2 buildsteps

Type: has_many

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::BuildSteps",
  { "foreign.build" => "self.id" },
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

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.build" => "self.id" },
  {},
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.build" => "self.id" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2012-02-29 00:47:54
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:VnnyFTwnLncGb2Dj2/giiA

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
  "resultInfo",
  "Hydra::Schema::BuildResultInfo",
  { id => "id" },
);

__PACKAGE__->has_one(
  "actualBuildStep",
  "Hydra::Schema::BuildSteps",
  { 'foreign.outpath' => 'self.outpath' 
  , 'foreign.build' => 'self.id'
  },
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
          join BuildResultInfo r using (id)
          left join Builds b on
            b.id =
              (select max(c.id)
               from builds c join buildresultinfo r2 on c.id = r2.id
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
            x.nixExprPath, x.maxsilent, x.timeout, x.priority, x.busy, x.locker,
            x.logfile, x.disabled, x.startTime,
            b.id as statusChangeId, b.timestamp as statusChangeTime
          from
            (select  
               (select max(b.id) from builds b
                where 
                  project = activeJobs.project and jobset = activeJobs.jobset 
                  and job = activeJobs.job and system = activeJobs.system 
                  and finished = 1
               ) as id
             from $activeJobs as activeJobs
            ) as latest
          join Builds x using (id)
          $joinWithStatusChange
QUERY
    );

    makeSource("ActiveJobs$name", "(select distinct project, jobset, job from Builds where isCurrent = 1 $constraint)");
    
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
                  and finished = 1
                  and exists (select 1 from buildresultinfo where id = b.id and buildstatus = 0)
               ) as id
             from $activeJobs as activeJobs
            ) as latest
          join Builds using (id)
QUERY
    );
}

addSequence;

makeQueries('', "");
makeQueries('ForProject', "and project = ?");
makeQueries('ForJobset', "and project = ? and jobset = ?");
makeQueries('ForJob', "and project = ? and jobset = ? and job = ?");


1;
