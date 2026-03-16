use utf8;
package Hydra::Schema::Result::StarredJobs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::StarredJobs

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

=head1 TABLE: C<starredjobs>

=cut

__PACKAGE__->table("starredjobs");

=head1 ACCESSORS

=head2 username

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 job

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "job",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</username>

=item * L</project>

=item * L</jobset>

=item * L</job>

=back

=cut

__PACKAGE__->set_primary_key("username", "project", "jobset", "job");

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

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Result::Projects>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Hydra::Schema::Result::Projects",
  { name => "project" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 username

Type: belongs_to

Related object: L<Hydra::Schema::Result::Users>

=cut

__PACKAGE__->belongs_to(
  "username",
  "Hydra::Schema::Result::Users",
  { username => "username" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:j+dXc22FIqlCSmP3mOX+Aw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
