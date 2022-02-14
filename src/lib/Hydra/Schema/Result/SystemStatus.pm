use utf8;

package Hydra::Schema::Result::SystemStatus;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::SystemStatus

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

=head1 TABLE: C<systemstatus>

=cut

__PACKAGE__->table("systemstatus");

=head1 ACCESSORS

=head2 what

  data_type: 'text'
  is_nullable: 0

=head2 status

  data_type: 'json'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
    "what",   { data_type => "text", is_nullable => 0 },
    "status", { data_type => "json", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</what>

=back

=cut

__PACKAGE__->set_primary_key("what");

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Ps8gKPEnK1tTa/hXYz+27A

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
