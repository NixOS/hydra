package Hydra::Schema::SystemTypes;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::SystemTypes

=cut

__PACKAGE__->table("SystemTypes");

=head1 ACCESSORS

=head2 system

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 maxconcurrent

  data_type: integer
  default_value: 2
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "system",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "maxconcurrent",
  { data_type => "integer", default_value => 2, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("system");


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:cY3UlAd8a/jARP5klFLP6g

1;
