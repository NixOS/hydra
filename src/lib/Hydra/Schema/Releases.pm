package Hydra::Schema::Releases;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::Releases

=cut

__PACKAGE__->table("Releases");

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

=head2 timestamp

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 description

  data_type: text
  default_value: undef
  is_nullable: 1
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
  "timestamp",
  {
    data_type => "integer",
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
);
__PACKAGE__->set_primary_key("project", "name");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 releasemembers

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "releasemembers",
  "Hydra::Schema::ReleaseMembers",
  {
    "foreign.project"  => "self.project",
    "foreign.release_" => "self.name",
  },
);


# Created by DBIx::Class::Schema::Loader v0.05003 @ 2010-02-25 10:29:41
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:tUuuHG9duLzmDhUywM+ErQ

1;
