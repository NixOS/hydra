use utf8;
package Hydra::Schema::Result::SystemTypes;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::SystemTypes

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

=head1 TABLE: C<systemtypes>

=cut

__PACKAGE__->table("systemtypes");

=head1 ACCESSORS

=head2 system

  data_type: 'text'
  is_nullable: 0

=head2 maxconcurrent

  data_type: 'integer'
  default_value: 2
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "system",
  { data_type => "text", is_nullable => 0 },
  "maxconcurrent",
  { data_type => "integer", default_value => 2, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</system>

=back

=cut

__PACKAGE__->set_primary_key("system");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:skzz9Wqwox5QO35YSgVXbw

1;
