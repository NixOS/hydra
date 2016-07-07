use utf8;
package Hydra::Schema::JobsetEvals;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::JobsetEvals

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

=head1 TABLE: C<jobset_evals>

=cut

__PACKAGE__->table("jobset_evals");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobset_evals_id_seq'

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 timestamp

  data_type: 'integer'
  is_nullable: 0

=head2 checkout_time

  data_type: 'integer'
  is_nullable: 0

=head2 eval_time

  data_type: 'integer'
  is_nullable: 0

=head2 has_new_builds

  data_type: 'integer'
  is_nullable: 0

=head2 hash

  data_type: 'text'
  is_nullable: 0

=head2 nr_builds

  data_type: 'integer'
  is_nullable: 1

=head2 nr_succeeded

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "jobset_evals_id_seq",
  },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "timestamp",
  { data_type => "integer", is_nullable => 0 },
  "checkout_time",
  { data_type => "integer", is_nullable => 0 },
  "eval_time",
  { data_type => "integer", is_nullable => 0 },
  "has_new_builds",
  { data_type => "integer", is_nullable => 0 },
  "hash",
  { data_type => "text", is_nullable => 0 },
  "nr_builds",
  { data_type => "integer", is_nullable => 1 },
  "nr_succeeded",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 jobset_eval_inputs

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobset_eval_inputs",
  "Hydra::Schema::JobsetEvalInputs",
  { "foreign.eval" => "self.id" },
  undef,
);

=head2 jobset_eval_members

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobset_eval_members",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
  undef,
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Hydra::Schema::Projects",
  { name => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:A0hMYVW669C/L8mdmLNInw

__PACKAGE__->has_many(
  "buildIds",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
);

__PACKAGE__->many_to_many(builds => 'buildIds', 'build');

my %hint = (
    columns => [
        "has_new_builds",
        "id"
    ],
    relations => {
        "builds" => "id"
    },
    eager_relations => {
        # altnr? Does anyone care?
        jobset_eval_inputs => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
