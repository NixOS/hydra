use utf8;
package Hydra::Schema::JobsetInputAlts;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::JobsetInputAlts

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<JobsetInputAlts>

=cut

__PACKAGE__->table("JobsetInputAlts");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 input

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 altnr

  data_type: 'integer'
  is_nullable: 0

=head2 value

  data_type: 'text'
  is_nullable: 1

=head2 revision

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "input",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "altnr",
  { data_type => "integer", is_nullable => 0 },
  "value",
  { data_type => "text", is_nullable => 1 },
  "revision",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</jobset>

=item * L</input>

=item * L</altnr>

=back

=cut

__PACKAGE__->set_primary_key("project", "jobset", "input", "altnr");

=head1 RELATIONS

=head2 jobsetinput

Type: belongs_to

Related object: L<Hydra::Schema::JobsetInputs>

=cut

__PACKAGE__->belongs_to(
  "jobsetinput",
  "Hydra::Schema::JobsetInputs",
  { jobset => "jobset", name => "input", project => "project" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2012-04-15 12:38:16
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:M1pOjrCZ2RgULsIPZjN7sg

1;
