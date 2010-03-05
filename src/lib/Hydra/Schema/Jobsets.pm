package Hydra::Schema::Jobsets;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Jobsets

=cut

__PACKAGE__->table("Jobsets");

=head1 ACCESSORS

=head2 name

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 project

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 nixexprinput

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 nixexprpath

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 errormsg

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 errortime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 lastcheckedtime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 enabled

  data_type: integer
  default_value: 1
  is_nullable: 0
  size: undef

=head2 enableemail

  data_type: integer
  default_value: 1
  is_nullable: 0
  size: undef

=head2 emailoverride

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
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
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "nixexprinput",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "nixexprpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "errormsg",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "errortime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "lastcheckedtime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "enableemail",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "emailoverride",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("project", "name");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 jobsetinput

Type: belongs_to

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->belongs_to(
  "jobsetinput",
  "Hydra::Schema::JobsetInputs",
  { jobset => "name", name => "nixexprinput", project => "project" },
  {},
);

=head2 jobsetinputs

Type: has_many

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->has_many(
  "jobsetinputs",
  "Hydra::Schema::JobsetInputs",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
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
);

=head2 jobsetevals

Type: has_many

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobsetevals",
  "Hydra::Schema::JobsetEvals",
  {
    "foreign.jobset"  => "self.name",
    "foreign.project" => "self.project",
  },
);


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-03-05 13:07:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Z0HutYxnzYVuQc3W51mq5Q

1;
