use utf8;
package Hydra::Schema::SchemaVersion;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::SchemaVersion

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<SchemaVersion>

=cut

__PACKAGE__->table("SchemaVersion");

=head1 ACCESSORS

=head2 version

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "version",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</version>

=back

=cut

__PACKAGE__->set_primary_key("version");


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:F/jsSRq8pxR4mWq/N4qYGw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
