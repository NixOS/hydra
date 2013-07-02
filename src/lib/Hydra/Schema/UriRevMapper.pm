use utf8;
package Hydra::Schema::UriRevMapper;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::UriRevMapper

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

=head1 TABLE: C<UriRevMapper>

=cut

__PACKAGE__->table("UriRevMapper");

=head1 ACCESSORS

=head2 baseuri

  data_type: 'text'
  is_nullable: 0

=head2 uri

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "baseuri",
  { data_type => "text", is_nullable => 0 },
  "uri",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</baseuri>

=back

=cut

__PACKAGE__->set_primary_key("baseuri");


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-06-13 01:54:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:G2GAF/Rb7cRkRegH94LwIA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
