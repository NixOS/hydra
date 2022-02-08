use utf8;
package Hydra::Schema::Result::JobsetInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::JobsetInputs

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

=head1 TABLE: C<jobsetinputs>

=cut

__PACKAGE__->table("jobsetinputs");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 type

  data_type: 'text'
  is_nullable: 0

=head2 value

  data_type: 'text'
  is_nullable: 1

=head2 revision

  data_type: 'text'
  is_nullable: 1

=head2 emailresponsible

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "type",
  { data_type => "text", is_nullable => 0 },
  "value",
  { data_type => "text", is_nullable => 1 },
  "revision",
  { data_type => "text", is_nullable => 1 },
  "emailresponsible",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</jobset>

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("project", "jobset", "name");

=head1 RELATIONS

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Result::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Result::Jobsets",
  { name => "jobset", project => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-02-07 22:35:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:3q9uqG91vDgfiEhBHQ7gJQ

use JSON::MaybeXS;

sub as_json {
    my $self = shift;

    my %json = (
        # string_columns
        "name" => $self->get_column("name") // "",
        "type" => $self->get_column("type") // "",
        "value" => $self->get_column("value") // "",

        # boolean_columns
        "emailresponsible" => $self->get_column("emailresponsible") ? JSON::MaybeXS::true : JSON::MaybeXS::false,
    );

    return \%json;
}

1;
