use utf8;
package Hydra::Schema::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Users

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

=head1 TABLE: C<Users>

=cut

__PACKAGE__->table("Users");

=head1 ACCESSORS

=head2 username

  data_type: 'text'
  is_nullable: 0

=head2 fullname

  data_type: 'text'
  is_nullable: 1

=head2 emailaddress

  data_type: 'text'
  is_nullable: 0

=head2 password

  data_type: 'text'
  is_nullable: 0

=head2 emailonerror

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0 },
  "fullname",
  { data_type => "text", is_nullable => 1 },
  "emailaddress",
  { data_type => "text", is_nullable => 0 },
  "password",
  { data_type => "text", is_nullable => 0 },
  "emailonerror",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</username>

=back

=cut

__PACKAGE__->set_primary_key("username");

=head1 RELATIONS

=head2 newsitems

Type: has_many

Related object: L<Hydra::Schema::NewsItems>

=cut

__PACKAGE__->has_many(
  "newsitems",
  "Hydra::Schema::NewsItems",
  { "foreign.author" => "self.username" },
  undef,
);

=head2 projectmembers

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "projectmembers",
  "Hydra::Schema::ProjectMembers",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects_2s

Type: has_many

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->has_many(
  "projects_2s",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
  undef,
);

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::StarredJobs",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 userroles

Type: has_many

Related object: L<Hydra::Schema::UserRoles>

=cut

__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects

Type: many_to_many

Composing rels: L</projectmembers> -> project

=cut

__PACKAGE__->many_to_many("projects", "projectmembers", "project");


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-10-14 15:46:29
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Hv9Ukqud0d3uIUot0ErKeg

my %hint = (
    columns => [
        "fullname",
        "emailaddress",
        "username"
    ],
    relations => {
        userroles => "role"
    }
);

sub json_hint {
    return \%hint;
}

1;
