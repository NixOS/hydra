use utf8;
package Hydra::Schema::Result::FailedPaths;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::FailedPaths

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

=head1 TABLE: C<failedpaths>

=cut

__PACKAGE__->table("failedpaths");

=head1 ACCESSORS

=head2 path

  data_type: 'text'
  is_nullable: 0

=head2 storedir

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "path",
  { data_type => "text", is_nullable => 0 },
  "storedir",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</path>

=back

=cut

__PACKAGE__->set_primary_key("path");

=head1 UNIQUE CONSTRAINTS

=head2 C<failedpaths_storedir_path_key>

=over 4

=item * L</storedir>

=item * L</path>

=back

=cut

__PACKAGE__->add_unique_constraint("failedpaths_storedir_path_key", ["storedir", "path"]);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2026-08-05 13:45:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:jaI0D8kOdwNw52eGcNz6HA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
__PACKAGE__->load_components("+Hydra::Component::InflateStorePath");
__PACKAGE__->inflate_store_paths(qw/path/);

1;

