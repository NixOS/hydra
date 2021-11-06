use utf8;
package Hydra::Schema::Result::Maintainer;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::Maintainer

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

=head1 TABLE: C<maintainers>

=cut

__PACKAGE__->table("maintainers");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'maintainers_id_seq'

=head2 email

  data_type: 'text'
  is_nullable: 0

=head2 github_handle

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "maintainers_id_seq",
  },
  "email",
  { data_type => "text", is_nullable => 0 },
  "github_handle",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<maintainers_email_key>

=over 4

=item * L</email>

=back

=cut

__PACKAGE__->add_unique_constraint("maintainers_email_key", ["email"]);

=head1 RELATIONS

=head2 buildsbymaintainers

Type: has_many

Related object: L<Hydra::Schema::Result::Buildsbymaintainer>

=cut

__PACKAGE__->has_many(
  "buildsbymaintainers",
  "Hydra::Schema::Result::Buildsbymaintainer",
  { "foreign.maintainer_id" => "self.id" },
  undef,
);

=head2 builds

Type: many_to_many

Composing rels: L</buildsbymaintainers> -> build

=cut

__PACKAGE__->many_to_many("builds", "buildsbymaintainers", "build");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-05 12:59:28
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:+5qSvX4RKp8fZ3a/qg98ZA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
