use utf8;
package Hydra::Schema::CachedCVSInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::CachedCVSInputs

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<CachedCVSInputs>

=cut

__PACKAGE__->table("CachedCVSInputs");

=head1 ACCESSORS

=head2 uri

  data_type: 'text'
  is_nullable: 0

=head2 module

  data_type: 'text'
  is_nullable: 0

=head2 timestamp

  data_type: 'integer'
  is_nullable: 0

=head2 lastseen

  data_type: 'integer'
  is_nullable: 0

=head2 sha256hash

  data_type: 'text'
  is_nullable: 0

=head2 storepath

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "uri",
  { data_type => "text", is_nullable => 0 },
  "module",
  { data_type => "text", is_nullable => 0 },
  "timestamp",
  { data_type => "integer", is_nullable => 0 },
  "lastseen",
  { data_type => "integer", is_nullable => 0 },
  "sha256hash",
  { data_type => "text", is_nullable => 0 },
  "storepath",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</uri>

=item * L</module>

=item * L</sha256hash>

=back

=cut

__PACKAGE__->set_primary_key("uri", "module", "sha256hash");


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:IcSVN/tlfQQtX88Ix+aKnw

# You can replace this text with custom content, and it will be preserved on regeneration
1;
