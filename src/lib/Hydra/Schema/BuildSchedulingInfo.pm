use utf8;
package Hydra::Schema::BuildSchedulingInfo;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildSchedulingInfo

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildSchedulingInfo>

=cut

__PACKAGE__->table("BuildSchedulingInfo");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_foreign_key: 1
  is_nullable: 0

=head2 priority

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 busy

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 locker

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 logfile

  data_type: 'text'
  is_nullable: 1

=head2 disabled

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 starttime

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_foreign_key    => 1,
    is_nullable       => 0,
  },
  "priority",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "busy",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "locker",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "logfile",
  { data_type => "text", is_nullable => 1 },
  "disabled",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 id

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("id", "Hydra::Schema::Builds", { id => "id" }, {});


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Uz7y9Ly+ADRrtrPfEk9lGA

# You can replace this text with custom content, and it will be preserved on regeneration
1;
