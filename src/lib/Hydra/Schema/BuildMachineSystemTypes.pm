use utf8;
package Hydra::Schema::BuildMachineSystemTypes;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildMachineSystemTypes

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildMachineSystemTypes>

=cut

__PACKAGE__->table("BuildMachineSystemTypes");

=head1 ACCESSORS

=head2 hostname

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "hostname",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</hostname>

=item * L</system>

=back

=cut

__PACKAGE__->set_primary_key("hostname", "system");

=head1 RELATIONS

=head2 hostname

Type: belongs_to

Related object: L<Hydra::Schema::BuildMachines>

=cut

__PACKAGE__->belongs_to(
  "hostname",
  "Hydra::Schema::BuildMachines",
  { hostname => "hostname" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:CpwMC8YMFC4B7gzGBdzh0A


# You can replace this text with custom content, and it will be preserved on regeneration
1;
