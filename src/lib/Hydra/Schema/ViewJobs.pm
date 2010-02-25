package Hydra::Schema::ViewJobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::ViewJobs

=cut

__PACKAGE__->table("ViewJobs");

=head1 ACCESSORS

=head2 project

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 view_

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 job

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 attrs

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 isprimary

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 jobset

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 autorelease

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
  "view_",
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
    is_nullable => 0,
    size => undef,
  },
  "attrs",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "isprimary",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "autorelease",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "view_", "job", "attrs");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 view

Type: belongs_to

Related object: L<Hydra::Schema::Views>

=cut

__PACKAGE__->belongs_to(
  "view",
  "Hydra::Schema::Views",
  { name => "view_", project => "project" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:+aFIv2sSlgMWKcQuWnq0fg

1;
