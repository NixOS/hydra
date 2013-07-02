use utf8;
package Hydra::Schema::ViewJobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::ViewJobs

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

=head1 TABLE: C<ViewJobs>

=cut

__PACKAGE__->table("ViewJobs");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 view_

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 job

  data_type: 'text'
  is_nullable: 0

=head2 attrs

  data_type: 'text'
  is_nullable: 0

=head2 isprimary

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 jobset

  data_type: 'text'
  is_nullable: 0

=head2 autorelease

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "view_",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "job",
  { data_type => "text", is_nullable => 0 },
  "attrs",
  { data_type => "text", is_nullable => 0 },
  "isprimary",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "jobset",
  { data_type => "text", is_nullable => 0 },
  "autorelease",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</view_>

=item * L</job>

=item * L</attrs>

=back

=cut

__PACKAGE__->set_primary_key("project", "view_", "job", "attrs");

=head1 RELATIONS

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

=head2 view

Type: belongs_to

Related object: L<Hydra::Schema::Views>

=cut

__PACKAGE__->belongs_to(
  "view",
  "Hydra::Schema::Views",
  { name => "view_", project => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07033 @ 2013-06-13 01:54:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hz912vBfYw0rHslBPqJW2w

1;
