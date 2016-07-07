use utf8;
package Hydra::Schema::BuildSteps;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildSteps

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

=head1 TABLE: C<build_steps>

=cut

__PACKAGE__->table("build_steps");

=head1 ACCESSORS

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 stepnr

  data_type: 'integer'
  is_nullable: 0

=head2 type

  data_type: 'integer'
  is_nullable: 0

=head2 drv_path

  data_type: 'text'
  is_nullable: 1

=head2 busy

  data_type: 'integer'
  is_nullable: 0

=head2 status

  data_type: 'integer'
  is_nullable: 1

=head2 error_msg

  data_type: 'text'
  is_nullable: 1

=head2 start_time

  data_type: 'integer'
  is_nullable: 1

=head2 stop_time

  data_type: 'integer'
  is_nullable: 1

=head2 machine

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 1

=head2 propagated_from

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 overhead

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "stepnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "integer", is_nullable => 0 },
  "drv_path",
  { data_type => "text", is_nullable => 1 },
  "busy",
  { data_type => "integer", is_nullable => 0 },
  "status",
  { data_type => "integer", is_nullable => 1 },
  "error_msg",
  { data_type => "text", is_nullable => 1 },
  "start_time",
  { data_type => "integer", is_nullable => 1 },
  "stop_time",
  { data_type => "integer", is_nullable => 1 },
  "machine",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 1 },
  "propagated_from",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "overhead",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</build>

=item * L</stepnr>

=back

=cut

__PACKAGE__->set_primary_key("build", "stepnr");

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

=head2 build_step_outputs

Type: has_many

Related object: L<Hydra::Schema::BuildStepOutputs>

=cut

__PACKAGE__->has_many(
  "build_step_outputs",
  "Hydra::Schema::BuildStepOutputs",
  { "foreign.build" => "self.build", "foreign.stepnr" => "self.stepnr" },
  undef,
);

=head2 propagated_from

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "propagated_from",
  "Hydra::Schema::Builds",
  { id => "propagated_from" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:EJC001O4YTrwl6W+eVWNgg

my %hint = (
    columns => [
        "machine",
        "system",
        "stepnr",
        "drv_path",
        "start_time",
    ],
    eager_relations => {
        build => 'id'
    }
);

sub json_hint {
    return \%hint;
}

1;
