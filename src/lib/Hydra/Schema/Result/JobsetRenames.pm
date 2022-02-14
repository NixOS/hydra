use utf8;

package Hydra::Schema::Result::JobsetRenames;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::JobsetRenames

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

=head1 TABLE: C<jobsetrenames>

=cut

__PACKAGE__->table("jobsetrenames");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 from_

  data_type: 'text'
  is_nullable: 0

=head2 to_

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
    "project", { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
    "from_",   { data_type => "text", is_nullable    => 0 },
    "to_",     { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</from_>

=back

=cut

__PACKAGE__->set_primary_key("project", "from_");

=head1 RELATIONS

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Result::Jobsets>

=cut

__PACKAGE__->belongs_to(
    "jobset",
    "Hydra::Schema::Result::Jobsets",
    { name => "to_", project => "project" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Result::Projects>

=cut

__PACKAGE__->belongs_to(
    "project",
    "Hydra::Schema::Result::Projects",
    { name          => "project" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Czt+7mIWn1e5IlzJYlj0vw

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
