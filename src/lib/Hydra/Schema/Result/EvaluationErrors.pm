use utf8;

package Hydra::Schema::Result::EvaluationErrors;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::EvaluationErrors

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

=head1 TABLE: C<evaluationerrors>

=cut

__PACKAGE__->table("evaluationerrors");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'evaluationerrors_id_seq'

=head2 errormsg

  data_type: 'text'
  is_nullable: 1

=head2 errortime

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
    "id",
    {
        data_type         => "integer",
        is_auto_increment => 1,
        is_nullable       => 0,
        sequence          => "evaluationerrors_id_seq",
    },
    "errormsg",
    { data_type => "text", is_nullable => 1 },
    "errortime",
    { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 jobsetevals

Type: has_many

Related object: L<Hydra::Schema::Result::JobsetEvals>

=cut

__PACKAGE__->has_many(
    "jobsetevals",
    "Hydra::Schema::Result::JobsetEvals",
    { "foreign.evaluationerror_id" => "self.id" }, undef,
);

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:QA8C+0TfW7unnM4xzOHXdA

__PACKAGE__->add_column("+id" => { retrieve_on_insert => 1 });

1;
