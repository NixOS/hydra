use utf8;
package Hydra::Schema::Result::JobsetEvals;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::JobsetEvals

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

=head1 TABLE: C<jobsetevals>

=cut

__PACKAGE__->table("jobsetevals");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobsetevals_id_seq'

=head2 jobset_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 evaluationerror_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 timestamp

  data_type: 'integer'
  is_nullable: 0

=head2 checkouttime

  data_type: 'integer'
  is_nullable: 0

=head2 evaltime

  data_type: 'integer'
  is_nullable: 0

=head2 hasnewbuilds

  data_type: 'integer'
  is_nullable: 0

=head2 hash

  data_type: 'text'
  is_nullable: 0

=head2 nrbuilds

  data_type: 'integer'
  is_nullable: 1

=head2 nrsucceeded

  data_type: 'integer'
  is_nullable: 1

=head2 flake

  data_type: 'text'
  is_nullable: 1

=head2 nixexprinput

  data_type: 'text'
  is_nullable: 1

=head2 nixexprpath

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "jobsetevals_id_seq",
  },
  "jobset_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "evaluationerror_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "timestamp",
  { data_type => "integer", is_nullable => 0 },
  "checkouttime",
  { data_type => "integer", is_nullable => 0 },
  "evaltime",
  { data_type => "integer", is_nullable => 0 },
  "hasnewbuilds",
  { data_type => "integer", is_nullable => 0 },
  "hash",
  { data_type => "text", is_nullable => 0 },
  "nrbuilds",
  { data_type => "integer", is_nullable => 1 },
  "nrsucceeded",
  { data_type => "integer", is_nullable => 1 },
  "flake",
  { data_type => "text", is_nullable => 1 },
  "nixexprinput",
  { data_type => "text", is_nullable => 1 },
  "nixexprpath",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 evaluationerror

Type: belongs_to

Related object: L<Hydra::Schema::Result::EvaluationErrors>

=cut

__PACKAGE__->belongs_to(
  "evaluationerror",
  "Hydra::Schema::Result::EvaluationErrors",
  { id => "evaluationerror_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "SET NULL",
    on_update     => "NO ACTION",
  },
);

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Result::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Result::Jobsets",
  { id => "jobset_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

=head2 jobsetevalinputs

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobsetevalinputs",
  "Hydra::Schema::Result::JobsetEvalInputs",
  { "foreign.eval" => "self.id" },
  undef,
);

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
  "Hydra::Schema::Result::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
  undef,
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:5qvXXTBDdRzgTEmJz6xC/g

__PACKAGE__->has_many(
  "buildIds",
  "Hydra::Schema::Result::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
);

__PACKAGE__->many_to_many(builds => 'buildIds', 'build');

my %hint = (
    columns => [
        "timestamp",
        "checkouttime",
        "evaltime",
        "hasnewbuilds",
        "id",
        "flake",
    ],
    relations => {
        "builds" => "id"
    },
    eager_relations => {
        # altnr? Does anyone care?
        jobsetevalinputs => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
