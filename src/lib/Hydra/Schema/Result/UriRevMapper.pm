use utf8;

package Hydra::Schema::Result::UriRevMapper;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::UriRevMapper

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

=head1 TABLE: C<urirevmapper>

=cut

__PACKAGE__->table("urirevmapper");

=head1 ACCESSORS

=head2 baseuri

  data_type: 'text'
  is_nullable: 0

=head2 uri

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
    "baseuri", { data_type => "text", is_nullable => 0 },
    "uri",     { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</baseuri>

=back

=cut

__PACKAGE__->set_primary_key("baseuri");

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:prycgyKZhOx4ch18xkoj1w

# You can replace this text with custom content, and it will be preserved on regeneration
1;
