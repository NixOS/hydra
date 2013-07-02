use utf8;
package Hydra::Schema::Projects;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Projects

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<Projects>

=cut

__PACKAGE__->table("Projects");

=head1 ACCESSORS

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 displayname

  data_type: 'text'
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 enabled

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 hidden

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 owner

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 homepage

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0 },
  "displayname",
  { data_type => "text", is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "hidden",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "owner",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "homepage",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("name");

=head1 RELATIONS

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobs

Type: has_many

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobsetevals

Type: has_many

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobsetevals",
  "Hydra::Schema::JobsetEvals",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobsets

Type: has_many

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 owner

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to(
  "owner",
  "Hydra::Schema::Users",
  { username => "owner" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "CASCADE" },
);

=head2 projectmembers

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "projectmembers",
  "Hydra::Schema::ProjectMembers",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 releases

Type: has_many

Related object: L<Hydra::Schema::Releases>

=cut

__PACKAGE__->has_many(
  "releases",
  "Hydra::Schema::Releases",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 viewjobs

Type: has_many

Related object: L<Hydra::Schema::ViewJobs>

=cut

__PACKAGE__->has_many(
  "viewjobs",
  "Hydra::Schema::ViewJobs",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 views

Type: has_many

Related object: L<Hydra::Schema::Views>

=cut

__PACKAGE__->has_many(
  "views",
  "Hydra::Schema::Views",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 usernames

Type: many_to_many

Composing rels: L</projectmembers> -> username

=cut

__PACKAGE__->many_to_many("usernames", "projectmembers", "username");


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-06-13 01:54:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:RffghAo9jAaqYk41y1Sdqw
# These lines were loaded from '/home/rbvermaa/src/hydra/src/lib/Hydra/Schema/Projects.pm' found in @INC.
# They are now part of the custom portion of this file
# for you to hand-edit.  If you do not either delete
# this section or remove that file from @INC, this section
# will be repeated redundantly when you re-create this
# file again via Loader!  See skip_load_external to disable
# this feature.

# You can replace this text with custom content, and it will be preserved on regeneration
1;
