package Hydra::Schema::Projects;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Projects

=cut

__PACKAGE__->table("Projects");

=head1 ACCESSORS

=head2 name

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 displayname

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 enabled

  data_type: integer
  default_value: 1
  is_nullable: 0
  size: undef

=head2 owner

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 homepage

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=cut

__PACKAGE__->add_columns(
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "displayname",
  {
    data_type => "text",
    default_value => undef,
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
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "owner",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "homepage",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("name");

=head1 RELATIONS

=head2 owner

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to("owner", "Hydra::Schema::Users", { username => "owner" }, {});

=head2 jobsets

Type: has_many

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  { "foreign.project" => "self.name" },
);

=head2 jobs

Type: has_many

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  { "foreign.project" => "self.name" },
);

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.project" => "self.name" },
);

=head2 views

Type: has_many

Related object: L<Hydra::Schema::Views>

=cut

__PACKAGE__->has_many(
  "views",
  "Hydra::Schema::Views",
  { "foreign.project" => "self.name" },
);

=head2 viewjobs

Type: has_many

Related object: L<Hydra::Schema::ViewJobs>

=cut

__PACKAGE__->has_many(
  "viewjobs",
  "Hydra::Schema::ViewJobs",
  { "foreign.project" => "self.name" },
);

=head2 releases

Type: has_many

Related object: L<Hydra::Schema::Releases>

=cut

__PACKAGE__->has_many(
  "releases",
  "Hydra::Schema::Releases",
  { "foreign.project" => "self.name" },
);

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.project" => "self.name" },
);

=head2 jobsetinputhashes

Type: has_many

Related object: L<Hydra::Schema::JobsetInputHashes>

=cut

__PACKAGE__->has_many(
  "jobsetinputhashes",
  "Hydra::Schema::JobsetInputHashes",
  { "foreign.project" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:yH/9hz6FH09kgusRNWrqPg

1;
