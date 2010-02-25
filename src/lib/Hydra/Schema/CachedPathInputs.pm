package Hydra::Schema::CachedPathInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::CachedPathInputs

=cut

__PACKAGE__->table("CachedPathInputs");

=head1 ACCESSORS

=head2 srcpath

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 timestamp

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 lastseen

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 sha256hash

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 storepath

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "srcpath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "timestamp",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "lastseen",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "sha256hash",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "storepath",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("srcpath", "sha256hash");


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:kZP1P7P2TMUCnnFPIGh1iA

1;
