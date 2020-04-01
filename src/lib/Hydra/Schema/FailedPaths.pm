use utf8;
package Hydra::Schema::FailedPaths;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::FailedPaths

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

=cut

__PACKAGE__->add_columns("path", { data_type => "text", is_nullable => 0 });

=head1 PRIMARY KEY

=over 4

=item * L</path>

=back

=cut

__PACKAGE__->set_primary_key("path");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-02-06 12:22:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:jr3XiGO4lWAzqfATbsMwFw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
