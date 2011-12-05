use utf8;
package Hydra::Schema::JobsetEvals;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::JobsetEvals

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<JobsetEvals>

=cut

__PACKAGE__->table("JobsetEvals");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 jobset

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 timestamp

  data_type: 'integer'
  is_nullable: 0

=head2 checkouttime

  data_type: 'integer'
  is_nullable: 0

=head2 evaltime

  data_type: 'integer'
  is_nullable: 0

=head2 hasnewbuilds

  data_type: 'integer'
  is_nullable: 0

=head2 hash

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "jobset",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "timestamp",
  { data_type => "integer", is_nullable => 0 },
  "checkouttime",
  { data_type => "integer", is_nullable => 0 },
  "evaltime",
  { data_type => "integer", is_nullable => 0 },
  "hasnewbuilds",
  { data_type => "integer", is_nullable => 0 },
  "hash",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

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
  {},
);

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:eQtF5bcR/qZ625LxWBc7ug

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
