use utf8;
package Hydra::Schema::Buildsbymaintainer;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Buildsbymaintainer

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

=head1 TABLE: C<buildsbymaintainers>

=cut

__PACKAGE__->table("buildsbymaintainers");

=head1 ACCESSORS

=head2 maintainer_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 build_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "maintainer_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "build_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</maintainer_id>

=item * L</build_id>

=back

=cut

__PACKAGE__->set_primary_key("maintainer_id", "build_id");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 maintainer

Type: belongs_to

Related object: L<Hydra::Schema::Maintainer>

=cut

__PACKAGE__->belongs_to(
  "maintainer",
  "Hydra::Schema::Maintainer",
  { id => "maintainer_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-04-26 17:23:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:6rnIt8vINy1Hk4n7Z6Kt+A


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
