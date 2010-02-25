package Hydra::Schema::JobsetInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::JobsetInputs

=cut

__PACKAGE__->table("JobsetInputs");

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

=head2 type

  data_type: text
  default_value: undef
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
  "type",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("project", "jobset", "name");

=head1 RELATIONS

=head2 jobsets

Type: has_many

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  {
    "foreign.name"         => "self.jobset",
    "foreign.nixexprinput" => "self.name",
    "foreign.project"      => "self.project",
  },
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

=head2 jobsetinputalts

Type: has_many

Related object: L<Hydra::Schema::JobsetInputAlts>

=cut

__PACKAGE__->has_many(
  "jobsetinputalts",
  "Hydra::Schema::JobsetInputAlts",
  {
    "foreign.input"   => "self.name",
    "foreign.jobset"  => "self.jobset",
    "foreign.project" => "self.project",
  },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:eThDu6WyuCUmDMEDlXyPkA

1;
