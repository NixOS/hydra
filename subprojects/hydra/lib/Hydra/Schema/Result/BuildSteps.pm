use utf8;
package Hydra::Schema::Result::BuildSteps;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::BuildSteps

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

=head1 TABLE: C<buildsteps>

=cut

__PACKAGE__->table("buildsteps");

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

=head2 drvpath

  data_type: 'text'
  is_nullable: 0

=head2 busy

  data_type: 'integer'
  is_nullable: 0

=head2 status

  data_type: 'integer'
  is_nullable: 1

=head2 errormsg

  data_type: 'text'
  is_nullable: 1

=head2 starttime

  data_type: 'bigint'
  is_nullable: 1

=head2 stoptime

  data_type: 'bigint'
  is_nullable: 1

=head2 machine

  data_type: 'text'
  default_value: (empty string)
  is_nullable: 0

=head2 system

  data_type: 'text'
  is_nullable: 1

=head2 propagatedfrom

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 overhead

  data_type: 'integer'
  is_nullable: 1

=head2 timesbuilt

  data_type: 'integer'
  is_nullable: 1

=head2 isnondeterministic

  data_type: 'boolean'
  is_nullable: 1

=head2 resolveddrvpath

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "stepnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "integer", is_nullable => 0 },
  "drvpath",
  { data_type => "text", is_nullable => 0 },
  "busy",
  { data_type => "integer", is_nullable => 0 },
  "status",
  { data_type => "integer", is_nullable => 1 },
  "errormsg",
  { data_type => "text", is_nullable => 1 },
  "starttime",
  { data_type => "integer", is_nullable => 1 },
  "stoptime",
  { data_type => "integer", is_nullable => 1 },
  "machine",
  { data_type => "text", default_value => "", is_nullable => 0 },
  "system",
  { data_type => "text", is_nullable => 1 },
  "propagatedfrom",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "overhead",
  { data_type => "integer", is_nullable => 1 },
  "timesbuilt",
  { data_type => "integer", is_nullable => 1 },
  "isnondeterministic",
  { data_type => "boolean", is_nullable => 1 },
  "resolveddrvpath",
  { data_type => "text", is_nullable => 1 },
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

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Result::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 buildstepoutputs

Type: has_many

Related object: L<Hydra::Schema::Result::BuildStepOutputs>

=cut

__PACKAGE__->has_many(
  "buildstepoutputs",
  "Hydra::Schema::Result::BuildStepOutputs",
  { "foreign.build" => "self.build", "foreign.stepnr" => "self.stepnr" },
  undef,
);

=head2 propagatedfrom

Type: belongs_to

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "propagatedfrom",
  "Hydra::Schema::Result::Builds",
  { id => "propagatedfrom" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2026-08-26 19:43:30
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:qId9Fo+ZRwiSBRXAi3IB+w

use File::Basename ();

# Find the step that this Resolved (status=13) step was resolved to, or
# undef if it hasn't been scheduled yet. Resolution is one-shot: a resolved
# derivation is basic (all inputs realized), so it can never itself be
# resolved again — there are no chains to follow. Corrupt resolveddrvpath
# values (a slash, a self-reference) simply match nothing here — the
# status filter below excludes Resolved rows, and the equality search is
# inert — so they render as "not scheduled" without special-casing.
sub resolved_terminal {
    my ($self) = @_;
    return undef unless (($self->status // -1) == 13) && $self->resolveddrvpath;
    # Resolution stays within the build that requested the work.
    # resolveddrvpath is a store-path basename, not a path; it lives in the
    # same store as this step's own drvpath, so derive the store dir from
    # that rather than global Nix state.
    return $self->result_source->resultset->search(
        {
            build   => $self->get_column('build'),
            drvpath => File::Basename::dirname($self->drvpath) . "/" . $self->resolveddrvpath,
            # A real terminal is never itself Resolved.
            status  => [ undef, { '!=' => 13 } ],
        },
        # A drv may have been attempted more than once; prefer succeeded
        # steps (lowest status), newest first. Busy steps have NULL
        # status and sort last.
        { order_by => [{ -asc => 'status' }, { -desc => 'stoptime' }],
          rows     => 1,
        }
    )->single;
}

# Every Resolved step in the same build that was resolved to this step's
# derivation.
sub resolution_origins {
    my ($self) = @_;
    return [ $self->result_source->resultset->search(
        {
            build           => $self->get_column('build'),
            status          => 13,
            resolveddrvpath => File::Basename::basename($self->drvpath),
        },
        { order_by => [{ -asc => 'stepnr' }] }
    )->all ];
}

my %hint = (
    columns => [
        "machine",
        "system",
        "stepnr",
        "drvpath",
        "starttime",
        "resolveddrvpath",
    ],
    eager_relations => {
        build => 'id'
    }
);

sub json_hint {
    return \%hint;
}

1;
