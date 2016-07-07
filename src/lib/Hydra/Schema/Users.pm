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

=head1 TABLE: C<users>

=cut

__PACKAGE__->table("users");

=head1 ACCESSORS

=head2 username

  data_type: 'text'
  is_nullable: 0

=head2 full_name

  data_type: 'text'
  is_nullable: 1

=head2 email_address

  data_type: 'text'
  is_nullable: 0

=head2 password

  data_type: 'text'
  is_nullable: 0

=head2 email_on_error

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 type

  data_type: 'text'
  default_value: 'hydra'
  is_nullable: 0

=head2 public_dashboard

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0 },
  "full_name",
  { data_type => "text", is_nullable => 1 },
  "email_address",
  { data_type => "text", is_nullable => 0 },
  "password",
  { data_type => "text", is_nullable => 0 },
  "email_on_error",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "type",
  { data_type => "text", default_value => "hydra", is_nullable => 0 },
  "public_dashboard",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</username>

=back

=cut

__PACKAGE__->set_primary_key("username");

=head1 RELATIONS

=head2 news_items

Type: has_many

Related object: L<Hydra::Schema::NewsItems>

=cut

__PACKAGE__->has_many(
  "news_items",
  "Hydra::Schema::NewsItems",
  { "foreign.author" => "self.username" },
  undef,
);

=head2 project_members

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "project_members",
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

=head2 starred_jobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starred_jobs",
  "Hydra::Schema::StarredJobs",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 user_roles

Type: has_many

Related object: L<Hydra::Schema::UserRoles>

=cut

__PACKAGE__->has_many(
  "user_roles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects

Type: many_to_many

Composing rels: L</project_members> -> project

=cut

__PACKAGE__->many_to_many("projects", "project_members", "project");


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4pzO1HKu+BvldbDU5mauBg

my %hint = (
    columns => [
        "full_name",
        "email_address",
        "username"
    ],
    relations => {
        user_roles => "role"
    }
);

sub json_hint {
    return \%hint;
}

1;
