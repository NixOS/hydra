use utf8;
package Hydra::Schema::JobsetEvalMembers;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::JobsetEvalMembers

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<JobsetEvalMembers>

=cut

__PACKAGE__->table("JobsetEvalMembers");

=head1 ACCESSORS

=head2 eval

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 isnew

  data_type: 'integer'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "eval",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "isnew",
  { data_type => "integer", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</eval>

=item * L</build>

=back

=cut

__PACKAGE__->set_primary_key("eval", "build");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 eval

Type: belongs_to

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->belongs_to(
  "eval",
  "Hydra::Schema::JobsetEvals",
  { id => "eval" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-01-22 13:29:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:EVwSR9WBqbBdIHq1ANQMHg


# You can replace this text with custom content, and it will be preserved on regeneration
1;
