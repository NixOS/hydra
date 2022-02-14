use utf8;

package Hydra::Schema::Result::CachedDarcsInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::CachedDarcsInputs

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

=head1 TABLE: C<cacheddarcsinputs>

=cut

__PACKAGE__->table("cacheddarcsinputs");

=head1 ACCESSORS

=head2 uri

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

=head2 revcount

  data_type: 'integer'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
    "uri",        { data_type => "text",    is_nullable => 0 },
    "revision",   { data_type => "text",    is_nullable => 0 },
    "sha256hash", { data_type => "text",    is_nullable => 0 },
    "storepath",  { data_type => "text",    is_nullable => 0 },
    "revcount",   { data_type => "integer", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</uri>

=item * L</revision>

=back

=cut

__PACKAGE__->set_primary_key("uri", "revision");

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:20pTv4R98jXytvlWbriWRg

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
