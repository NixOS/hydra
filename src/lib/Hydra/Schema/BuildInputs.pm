package Hydra::Schema::BuildInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::BuildInputs

=cut

__PACKAGE__->table("BuildInputs");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_auto_increment: 1
  is_nullable: 0
  size: undef

=head2 build

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 1
  size: undef

=head2 name

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 type

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 uri

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 revision

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 tag

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 value

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 dependency

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 1
  size: undef

=head2 path

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 sha256hash

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_auto_increment => 1,
    is_nullable => 0,
    size => undef,
  },
  "build",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 1,
    size => undef,
  },
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "type",
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
    is_nullable => 1,
    size => undef,
  },
  "revision",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "tag",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "value",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "dependency",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 1,
    size => undef,
  },
  "path",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "sha256hash",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build" },
  { join_type => "LEFT" },
);

=head2 dependency

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "dependency",
  "Hydra::Schema::Builds",
  { id => "dependency" },
  { join_type => "LEFT" },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:48U7D8+iCPaPc42KJCoQGg

use Hydra::Helper::Nix;

sub addSequence {
  my $hydradbi = getHydraDBPath ;
  if ($hydradbi =~ m/^dbi:Pg/) {
    __PACKAGE__->sequence('builds_id_seq');
  }
} 

addSequence ;

# You can replace this text with custom content, and it will be preserved on regeneration
1;
