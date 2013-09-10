use utf8;
package Hydra::Schema::CachedDarcsInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::CachedDarcsInputs

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<CachedDarcsInputs>

=cut

__PACKAGE__->table("CachedDarcsInputs");

=head1 ACCESSORS

=head2 uri

  data_type: 'text'
  is_nullable: 0

=head2 branch

  data_type: 'text'
  is_nullable: 0

=head2 revision

  data_type: 'text'
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
  "revision",
  { data_type => "text", is_nullable => 0 },
  "revcount",
  { data_type => "integer", is_nullable => 0 },
  "sha256hash",
  { data_type => "text", is_nullable => 0 },
  "storepath",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</uri>

=item * L</branch>

=item * L</revision>

=back

=cut

__PACKAGE__->set_primary_key("uri", "revision");


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:fx3yosWMmJ+MnvL/dSWtFA

1;
