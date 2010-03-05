package Hydra::Schema::JobsetEvalMembers;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::JobsetEvalMembers

=cut

__PACKAGE__->table("JobsetEvalMembers");

=head1 ACCESSORS

=head2 eval

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 build

  data_type: integer
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 isnew

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "eval",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "build",
  {
    data_type => "integer",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "isnew",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("eval", "build");

=head1 RELATIONS

=head2 eval

Type: belongs_to

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->belongs_to("eval", "Hydra::Schema::JobsetEvals", { id => "eval" }, {});

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" }, {});


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-03-05 13:07:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:vwefi8q3HolhFCkB9aEVWw


# You can replace this text with custom content, and it will be preserved on regeneration
1;
