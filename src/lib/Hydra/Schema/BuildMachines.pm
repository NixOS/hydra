use utf8;
package Hydra::Schema::BuildMachines;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildMachines

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildMachines>

=cut

__PACKAGE__->table("BuildMachines");

=head1 ACCESSORS

=head2 hostname

  data_type: 'text'
  is_nullable: 0

=head2 username

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 ssh_key

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 options

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 maxconcurrent

  data_type: 'integer'
  default_value: 2
  is_nullable: 0

=head2 speedfactor

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 enabled

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "hostname",
  { data_type => "text", is_nullable => 0 },
  "username",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "ssh_key",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "options",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "maxconcurrent",
  { data_type => "integer", default_value => 2, is_nullable => 0 },
  "speedfactor",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "enabled",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</hostname>

=back

=cut

__PACKAGE__->set_primary_key("hostname");

=head1 RELATIONS

=head2 buildmachinesystemtypes

Type: has_many

Related object: L<Hydra::Schema::BuildMachineSystemTypes>

=cut

__PACKAGE__->has_many(
  "buildmachinesystemtypes",
  "Hydra::Schema::BuildMachineSystemTypes",
  { "foreign.hostname" => "self.hostname" },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-01-22 13:29:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:OST5IMcvHKsXlNMCRazXhg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
