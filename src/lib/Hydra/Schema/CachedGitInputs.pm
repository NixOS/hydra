use utf8;
package Hydra::Schema::CachedGitInputs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::CachedGitInputs

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

=head1 TABLE: C<cachedgitinputs>

=cut

__PACKAGE__->table("cachedgitinputs");

=head1 ACCESSORS

=head2 uri

  data_type: 'text'
  is_nullable: 0

=head2 branch

  data_type: 'text'
  is_nullable: 0

=head2 revision

  data_type: 'text'
  is_nullable: 0

=head2 isdeepclone

  data_type: 'boolean'
  is_nullable: 0

=head2 sha256hash

  data_type: 'text'
  is_nullable: 0

=head2 storepath

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "uri",
  { data_type => "text", is_nullable => 0 },
  "branch",
  { data_type => "text", is_nullable => 0 },
  "revision",
  { data_type => "text", is_nullable => 0 },
  "isdeepclone",
  { data_type => "boolean", is_nullable => 0 },
  "sha256hash",
  { data_type => "text", is_nullable => 0 },
  "storepath",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</uri>

=item * L</branch>

=item * L</revision>

=item * L</isdeepclone>

=back

=cut

__PACKAGE__->set_primary_key("uri", "branch", "revision", "isdeepclone");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-06-19 17:26:24
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Wr0grsFTaqRlMeM9vpXjrw

1;
