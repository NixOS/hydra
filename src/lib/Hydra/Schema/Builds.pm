package Hydra::Schema::Builds;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("Builds");
__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0, size => undef },
  "finished",
  { data_type => "integer", is_nullable => 0, size => undef },
  "timestamp",
  { data_type => "integer", is_nullable => 0, size => undef },
  "project",
  { data_type => "text", is_nullable => 0, size => undef },
  "jobset",
  { data_type => "text", is_nullable => 0, size => undef },
  "job",
  { data_type => "text", is_nullable => 0, size => undef },
  "nixname",
  { data_type => "text", is_nullable => 0, size => undef },
  "description",
  { data_type => "text", is_nullable => 0, size => undef },
  "drvpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "outpath",
  { data_type => "text", is_nullable => 0, size => undef },
  "system",
  { data_type => "text", is_nullable => 0, size => undef },
  "longdescription",
  { data_type => "text", is_nullable => 0, size => undef },
  "license",
  { data_type => "text", is_nullable => 0, size => undef },
  "homepage",
  { data_type => "text", is_nullable => 0, size => undef },
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
__PACKAGE__->has_many(
  "buildschedulinginfoes",
  "Hydra::Schema::BuildSchedulingInfo",
  { "foreign.id" => "self.id" },
);
__PACKAGE__->has_many(
  "buildresultinfoes",
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


# Created by DBIx::Class::Schema::Loader v0.04005 @ 2009-03-13 13:33:20
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:xqKyjCWVdoTyQJC28K3WXA

use Hydra::Helper::Nix;

__PACKAGE__->has_many(dependents => 'Hydra::Schema::BuildInputs', 'dependency');

__PACKAGE__->many_to_many(dependentBuilds => 'dependents', 'build');

__PACKAGE__->has_many(inputs => 'Hydra::Schema::BuildInputs', 'build');

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

if (getHydraPath  =~ m/^dbi:Pg/) {
  __PACKAGE__->sequence('builds_id_seq');
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
    makeSource('JobStatus' . $name, "select * from (select project, jobset, job, system, max(id) as id from Builds where finished = 1 $constraint group by project, jobset, job, system) as a natural join Builds");
    makeSource('LatestSucceeded' . $name, "select * from (select project, jobset, job, system, max(id) as id from Builds natural join BuildResultInfo where finished = 1 and buildStatus = 0 $constraint group by project, jobset, job, system) as a natural join Builds");
}

makeQueries('', "");
makeQueries('ForProject', "and project = ?");
makeQueries('ForJobset', "and project = ? and jobset = ?");
makeQueries('ForJob', "and project = ? and jobset = ? and job = ?");


1;
