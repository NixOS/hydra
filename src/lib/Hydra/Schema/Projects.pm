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

=head1 TABLE: C<projects>

=cut

__PACKAGE__->table("projects");

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

=head2 declfile

  data_type: 'text'
  is_nullable: 1

=head2 decltype

  data_type: 'text'
  is_nullable: 1

=head2 declvalue

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
  "declfile",
  { data_type => "text", is_nullable => 1 },
  "decltype",
  { data_type => "text", is_nullable => 1 },
  "declvalue",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("name");

=head1 RELATIONS

=head2 buildmetrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "buildmetrics",
  "Hydra::Schema::BuildMetrics",
  { "foreign.project" => "self.name" },
  undef,
);

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

=head2 jobsetrenames

Type: has_many

Related object: L<Hydra::Schema::JobsetRenames>

=cut

__PACKAGE__->has_many(
  "jobsetrenames",
  "Hydra::Schema::JobsetRenames",
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

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::StarredJobs",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 usernames

Type: many_to_many

Composing rels: L</projectmembers> -> username

=cut

__PACKAGE__->many_to_many("usernames", "projectmembers", "username");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-01-22 07:11:57
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Ff5gJejFu+02b0lInobOoQ

my %hint = (
    columns => [
        "name",
        "displayname",
        "description",
        "enabled",
        "hidden",
        "owner"
    ],
    relations => {
        jobsets => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
