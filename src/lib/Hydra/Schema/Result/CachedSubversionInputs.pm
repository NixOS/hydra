use utf8;
package Hydra::Schema::Result::CachedSubversionInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::CachedSubversionInputs

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

=head1 TABLE: C<cachedsubversioninputs>

=cut

__PACKAGE__->table("cachedsubversioninputs");

=head1 ACCESSORS

=head2 uri

  data_type: 'text'
  is_nullable: 0

=head2 revision

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
  "revision",
  { data_type => "integer", is_nullable => 0 },
  "sha256hash",
  { data_type => "text", is_nullable => 0 },
  "storepath",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</uri>

=item * L</revision>

=back

=cut

__PACKAGE__->set_primary_key("uri", "revision");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:6kWslezt4Pb1H8gTW4EU6w

1;
