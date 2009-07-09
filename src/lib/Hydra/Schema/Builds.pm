package Hydra::Schema::Builds;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Builds");
__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
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
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" });
__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
);
__PACKAGE__->belongs_to(
  "job",
  "Hydra::Schema::Jobs",
  { jobset => "jobset", name => "job", project => "project" },
);
__PACKAGE__->might_have(
  "buildschedulinginfo",
  "Hydra::Schema::BuildSchedulingInfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->might_have(
  "buildresultinfo",
  "Hydra::Schema::BuildResultInfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildsteps",
  "Hydra::Schema::BuildSteps",
  { "foreign.build" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_builds",
  "Hydra::Schema::BuildInputs",
  { "foreign.build" => "self.id" },
);
__PACKAGE__->has_many(
  "buildinputs_dependencies",
  "Hydra::Schema::BuildInputs",
  { "foreign.dependency" => "self.id" },
);
__PACKAGE__->has_many(
  "buildproducts",
  "Hydra::Schema::BuildProducts",
  { "foreign.build" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-07-07 14:36:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:mTc++yn7RST163jLNJkXaw

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
        "natural join BuildResultInfo r " .
        "left join Builds b on b.id = " .
        "(select max(id) from builds c natural join buildresultinfo r2 " .
        "  where x.project = c.project and x.jobset = c.jobset and x.job = c.job and x.system = c.system and " .
        "    x.id > c.id and r.buildstatus != r2.buildstatus)";
    # Urgh, can't use "*" in the "select" here because of the status change join.
    makeSource('JobStatus' . $name, "select x.id, x.finished, x.timestamp, x.project, x.jobset, x.job, x.nixname, x.description, x.drvpath, x.outpath, x.system, x.longdescription, x.license, x.homepage, x.maintainers, b.id as statusChangeId, b.timestamp as statusChangeTime from (select project, jobset, job, system, max(id) as id from Builds where finished = 1 $constraint group by project, jobset, job, system) as latest natural join Builds x $joinWithStatusChange");
    makeSource('LatestSucceeded' . $name, "select * from (select project, jobset, job, system, max(id) as id from Builds natural join BuildResultInfo where finished = 1 and buildStatus = 0 $constraint group by project, jobset, job, system) as latest natural join Builds x");
}

addSequence;

makeQueries('', "");
makeQueries('ForProject', "and project = ?");
makeQueries('ForJobset', "and project = ? and jobset = ?");
makeQueries('ForJob', "and project = ? and jobset = ? and job = ?");


1;
