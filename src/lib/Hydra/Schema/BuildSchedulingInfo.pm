package Hydra::Schema::BuildSchedulingInfo;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildSchedulingInfo

=cut

__PACKAGE__->table("BuildSchedulingInfo");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 priority

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 busy

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 locker

  data_type: text
  default_value: (empty string)
  is_nullable: 0
  size: undef

=head2 logfile

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 disabled

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=head2 starttime

  data_type: integer
  default_value: undef
  is_nullable: 1
  size: undef

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "busy",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "locker",
  { data_type => "text", default_value => "", is_nullable => 0, size => undef },
  "logfile",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
  "starttime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 id

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" }, {});


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:yEhHeANRynKf72dp5URvZA

# You can replace this text with custom content, and it will be preserved on regeneration
1;
