use utf8;
package Hydra::Schema::Result::JobsetEvalInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::JobsetEvalInputs

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

=head1 TABLE: C<jobsetevalinputs>

=cut

__PACKAGE__->table("jobsetevalinputs");

=head1 ACCESSORS

=head2 eval

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 altnr

  data_type: 'integer'
  is_nullable: 0

=head2 type

  data_type: 'text'
  is_nullable: 0

=head2 uri

  data_type: 'text'
  is_nullable: 1

=head2 revision

  data_type: 'text'
  is_nullable: 1

=head2 value

  data_type: 'text'
  is_nullable: 1

=head2 dependency

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 path

  data_type: 'text'
  is_nullable: 1

=head2 sha256hash

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "eval",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "altnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "text", is_nullable => 0 },
  "uri",
  { data_type => "text", is_nullable => 1 },
  "revision",
  { data_type => "text", is_nullable => 1 },
  "value",
  { data_type => "text", is_nullable => 1 },
  "dependency",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "path",
  { data_type => "text", is_nullable => 1 },
  "sha256hash",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</eval>

=item * L</name>

=item * L</altnr>

=back

=cut

__PACKAGE__->set_primary_key("eval", "name", "altnr");

=head1 RELATIONS

=head2 dependency

Type: belongs_to

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "dependency",
  "Hydra::Schema::Result::Builds",
  { id => "dependency" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

=head2 eval

Type: belongs_to

Related object: L<Hydra::Schema::Result::JobsetEvals>

=cut

__PACKAGE__->belongs_to(
  "eval",
  "Hydra::Schema::Result::JobsetEvals",
  { id => "eval" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:AgMH2XIxp7519fFaYgesVw

my %hint = (
    columns => [
        "revision",
        "value",
        "type",
        "uri",
        'dependency',
    ],
);

sub json_hint {
    return \%hint;
}

1;
