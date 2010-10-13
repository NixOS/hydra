package Hydra::Schema::BuildMachineSystemTypes;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildMachineSystemTypes

=cut

__PACKAGE__->table("BuildMachineSystemTypes");

=head1 ACCESSORS

=head2 hostname

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 system

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "hostname",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "system",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
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


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-10-08 13:47:26
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:F/voQZLNESTotUOWRbg4WA


# You can replace this text with custom content, and it will be preserved on regeneration
1;
