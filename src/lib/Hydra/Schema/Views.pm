package Hydra::Schema::Views;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Views

=cut

__PACKAGE__->table("Views");

=head1 ACCESSORS

=head2 project

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 name

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
  size: undef

=head2 keep

  data_type: integer
  default_value: 0
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "name",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "description",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 1,
    size => undef,
  },
  "keep",
  { data_type => "integer", default_value => 0, is_nullable => 0, size => undef },
);
__PACKAGE__->set_primary_key("project", "name");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 viewjobs

Type: has_many

Related object: L<Hydra::Schema::ViewJobs>

=cut

__PACKAGE__->has_many(
  "viewjobs",
  "Hydra::Schema::ViewJobs",
  { "foreign.project" => "self.project", "foreign.view_" => "self.name" },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Ziocg+WjpiRs3lmlPJL4YA

1;
