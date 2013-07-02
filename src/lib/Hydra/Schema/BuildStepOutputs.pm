use utf8;
package Hydra::Schema::BuildStepOutputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildStepOutputs

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

=head1 TABLE: C<BuildStepOutputs>

=cut

__PACKAGE__->table("BuildStepOutputs");

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
  { data_type => "text", is_nullable => 0 },
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

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 buildstep

Type: belongs_to

Related object: L<Hydra::Schema::BuildSteps>

=cut

__PACKAGE__->belongs_to(
  "buildstep",
  "Hydra::Schema::BuildSteps",
  { build => "build", stepnr => "stepnr" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-06-13 01:54:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:A/4v3ugXYbuYoKPlOvC6mg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
