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

=head1 TABLE: C<jobsetevals>

=cut

__PACKAGE__->table("jobsetevals");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobsetevals_id_seq'

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 errormsg

  data_type: 'text'
  is_nullable: 1

=head2 errortime

  data_type: 'integer'
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

=head2 nixexprinput

  data_type: 'text'
  is_nullable: 1

=head2 nixexprpath

  data_type: 'text'
  is_nullable: 1

=head2 nrbuilds

  data_type: 'integer'
  is_nullable: 1

=head2 nrsucceeded

  data_type: 'integer'
  is_nullable: 1

=head2 flake

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
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "errormsg",
  { data_type => "text", is_nullable => 1 },
  "errortime",
  { data_type => "integer", is_nullable => 1 },
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
  "nixexprinput",
  { data_type => "text", is_nullable => 1 },
  "nixexprpath",
  { data_type => "text", is_nullable => 1 },
  "nrbuilds",
  { data_type => "integer", is_nullable => 1 },
  "nrsucceeded",
  { data_type => "integer", is_nullable => 1 },
  "flake",
  { data_type => "text", is_nullable => 1 },
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

=head2 jobsetevalinputs

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalInputs>

=cut

__PACKAGE__->has_many(
  "jobsetevalinputs",
  "Hydra::Schema::JobsetEvalInputs",
  { "foreign.eval" => "self.id" },
  undef,
);

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-01-22 07:11:57
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hdu+0WWo2363dVvImMKxdA

__PACKAGE__->has_many(
  "buildIds",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
);

__PACKAGE__->many_to_many(builds => 'buildIds', 'build');

my %hint = (
    columns => [
        "hasnewbuilds",
        "id"
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
