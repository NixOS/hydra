use utf8;
package Hydra::Schema::Result::BuildStepOutputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::BuildStepOutputs

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<buildstepoutputs>

=cut

__PACKAGE__->table("buildstepoutputs");

=head1 ACCESSORS

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 stepnr

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 path

  data_type: 'text'
  is_nullable: 1

=head2 contentaddressed

  data_type: 'boolean'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "stepnr",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "path",
  { data_type => "text", is_nullable => 1 },
  "contentaddressed",
  { data_type => "boolean", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</build>

=item * L</stepnr>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("build", "stepnr", "name");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Result::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 buildstep

Type: belongs_to

Related object: L<Hydra::Schema::Result::BuildSteps>

=cut

__PACKAGE__->belongs_to(
  "buildstep",
  "Hydra::Schema::Result::BuildSteps",
  { build => "build", stepnr => "stepnr" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-06-30 12:02:32
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Bad70CRTt7zb2GGuRoQ++Q


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
