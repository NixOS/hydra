package Hydra::Schema::CachedSubversionInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::CachedSubversionInputs

=cut

__PACKAGE__->table("CachedSubversionInputs");

=head1 ACCESSORS

=head2 uri

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 revision

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
  "uri",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "revision",
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
__PACKAGE__->set_primary_key("uri", "revision");


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:X5cnk1/P6U0SzCCQr72rBg

1;
