package Hydra::Schema::JobsetEvals;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';


=head1 NAME

Hydra::Schema::JobsetEvals

=cut

__PACKAGE__->table("JobsetEvals");

=head1 ACCESSORS

=head2 id

  data_type: integer
  default_value: undef
  is_auto_increment: 1
  is_nullable: 0
  size: undef

=head2 project

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 jobset

  data_type: text
  default_value: undef
  is_foreign_key: 1
  is_nullable: 0
  size: undef

=head2 timestamp

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 checkouttime

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 evaltime

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 hasnewbuilds

  data_type: integer
  default_value: undef
  is_nullable: 0
  size: undef

=head2 hash

  data_type: text
  default_value: undef
  is_nullable: 0
  size: undef

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    default_value => undef,
    is_auto_increment => 1,
    is_nullable => 0,
    size => undef,
  },
  "project",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
    is_nullable => 0,
    size => undef,
  },
  "jobset",
  {
    data_type => "text",
    default_value => undef,
    is_foreign_key => 1,
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
  "checkouttime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "evaltime",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "hasnewbuilds",
  {
    data_type => "integer",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
  "hash",
  {
    data_type => "text",
    default_value => undef,
    is_nullable => 0,
    size => undef,
  },
);
__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 jobset

Type: belongs_to

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->belongs_to(
  "jobset",
  "Hydra::Schema::Jobsets",
  { name => "jobset", project => "project" },
  {},
);

=head2 jobsetevalmembers

Type: has_many

Related object: L<Hydra::Schema::JobsetEvalMembers>

=cut

__PACKAGE__->has_many(
  "jobsetevalmembers",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
);


# Created by DBIx::Class::Schema::Loader v0.05000 @ 2010-03-05 13:33:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:QD7ZMOLp9HpK0mAYkk0d/Q

use Hydra::Helper::Nix;

# !!! Ugly, should be generated.
my $hydradbi = getHydraDBPath;
if ($hydradbi =~ m/^dbi:Pg/) {
    __PACKAGE__->sequence('jobsetevals_id_seq');
}

__PACKAGE__->has_many(
  "buildIds",
  "Hydra::Schema::JobsetEvalMembers",
  { "foreign.eval" => "self.id" },
);

__PACKAGE__->many_to_many(builds => 'buildIds', 'build');

# You can replace this text with custom content, and it will be preserved on regeneration
1;
