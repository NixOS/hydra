package Hydra::Schema::Jobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Jobs

=cut

__PACKAGE__->table("Jobs");

=head1 ACCESSORS

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

=head2 name

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 active

  data_type: integer
  default_value: 1
  is_nullable: 0
  size: undef

=head2 errormsg

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 firstevaltime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 lastevaltime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=head2 disabled

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
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
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "active",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "errormsg",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "firstevaltime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "lastevaltime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "jobset", "name");

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
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:MA9QPD0BcewmJazzmSu1MA

1;
