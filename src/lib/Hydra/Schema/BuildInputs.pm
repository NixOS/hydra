package Hydra::Schema::BuildInputs;

use strict;
use warnings;

use base 'DBIx::Class';

__PACKAGE__->load_components("Core");
__PACKAGE__->table("BuildInputs");
__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
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
    data_type => "integer",
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
__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build" },
  { join_type => "LEFT OUTER" },
);
__PACKAGE__->belongs_to(
  "dependency",
  "Hydra::Schema::Builds",
  { id => "dependency" },
  { join_type => "LEFT OUTER" },
);


# Created by DBIx::Class::Schema::Loader v0.04999_06 @ 2009-10-21 17:40:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:IrEeOAeGZJUN3/kCMRNy5g

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
