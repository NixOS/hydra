package Hydra::Schema::BuildMachines;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildMachines

=cut

__PACKAGE__->table("BuildMachines");

=head1 ACCESSORS

=head2 hostname

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 username

  data_type: text
  default_value: ''
  is_nullable: 0
  size: undef

=head2 ssh_key

  data_type: text
  default_value: ''
  is_nullable: 0
  size: undef

=head2 options

  data_type: text
  default_value: ''
  is_nullable: 0
  size: undef

=head2 maxconcurrent

  data_type: integer
  default_value: 2
  is_nullable: 0
  size: undef

=head2 speedfactor

  data_type: integer
  default_value: 1
  is_nullable: 0
  size: undef

=head2 enabled

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "hostname",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "username",
  { data_type => "text", default_value => "''", is_nullable => 0, size => undef },
  "ssh_key",
  { data_type => "text", default_value => "''", is_nullable => 0, size => undef },
  "options",
  { data_type => "text", default_value => "''", is_nullable => 0, size => undef },
  "maxconcurrent",
  { data_type => "integer", default_value => 2, is_nullable => 0, size => undef },
  "speedfactor",
  { data_type => "integer", default_value => 1, is_nullable => 0, size => undef },
  "enabled",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
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
);


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-11-11 10:58:44
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:GV0LlwTyjFctix2zArVTGw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
