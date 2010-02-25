package Hydra::Schema::JobsetInputAlts;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::JobsetInputAlts

=cut

__PACKAGE__->table("JobsetInputAlts");

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

=head2 input

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 altnr

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 value

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 revision

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 tag

  data_type: text
  default_value: undef
  is_nullable: 1
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
  "input",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "altnr",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "value",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "revision",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "tag",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("project", "jobset", "input", "altnr");

=head1 RELATIONS

=head2 jobsetinput

Type: belongs_to

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->belongs_to(
  "jobsetinput",
  "Hydra::Schema::JobsetInputs",
  { jobset => "jobset", name => "input", project => "project" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:l75rIU6dDqdHBkPIaC+84w

1;
