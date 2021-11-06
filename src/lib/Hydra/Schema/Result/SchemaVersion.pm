use utf8;
package Hydra::Schema::Result::SchemaVersion;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::SchemaVersion

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

=head1 TABLE: C<schemaversion>

=cut

__PACKAGE__->table("schemaversion");

=head1 ACCESSORS

=head2 version

  data_type: 'integer'
  is_nullable: 0

=cut

__PACKAGE__->add_columns("version", { data_type => "integer", is_nullable => 0 });


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:GAlywxH9wpqRoD36GobQvA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
