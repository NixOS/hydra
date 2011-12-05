use utf8;
package Hydra::Schema::BuildInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildInputs

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<BuildInputs>

=cut

__PACKAGE__->table("BuildInputs");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 type

  data_type: 'text'
  is_nullable: 0

=head2 uri

  data_type: 'text'
  is_nullable: 1

=head2 revision

  data_type: 'text'
  is_nullable: 1

=head2 tag

  data_type: 'text'
  is_nullable: 1

=head2 value

  data_type: 'text'
  is_nullable: 1

=head2 dependency

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 path

  data_type: 'text'
  is_nullable: 1

=head2 sha256hash

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "type",
  { data_type => "text", is_nullable => 0 },
  "uri",
  { data_type => "text", is_nullable => 1 },
  "revision",
  { data_type => "text", is_nullable => 1 },
  "tag",
  { data_type => "text", is_nullable => 1 },
  "value",
  { data_type => "text", is_nullable => 1 },
  "dependency",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "path",
  { data_type => "text", is_nullable => 1 },
  "sha256hash",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

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


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:yaqa9gcGx9Z+Nfr3xgX28g

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
