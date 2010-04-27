package Hydra::Schema::NewsItems;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::NewsItems

=cut

__PACKAGE__->table("NewsItems");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_auto_increment: 1
  is_nullable: 0
  size: undef

=head2 contents

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 createtime

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 author

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
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
  "contents",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "createtime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "author",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 author

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to("author", "Hydra::Schema::Users", { username => "author" }, {});


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-04-27 15:13:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:SX13YZYhf5Uz5KZGphG/+w

use Hydra::Helper::Nix;

# !!! Ugly, should be generated.
my $hydradbi = getHydraDBPath;
if ($hydradbi =~ m/^dbi:Pg/) {
    __PACKAGE__->sequence('newsitems_id_seq');
}

1;
