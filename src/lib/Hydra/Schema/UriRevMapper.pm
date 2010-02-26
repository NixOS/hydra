package Hydra::Schema::UriRevMapper;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::UriRevMapper

=cut

__PACKAGE__->table("UriRevMapper");

=head1 ACCESSORS

=head2 baseuri

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 uri

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "baseuri",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "uri",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("baseuri");


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 12:58:30
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:r3ricsHLJ6t/8kg+5Gu5Qw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
