use utf8;
package Hydra::Schema::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Users

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

=head1 TABLE: C<users>

=cut

__PACKAGE__->table("users");

=head1 ACCESSORS

=head2 username

  data_type: 'text'
  is_nullable: 0

=head2 fullname

  data_type: 'text'
  is_nullable: 1

=head2 emailaddress

  data_type: 'text'
  is_nullable: 0

=head2 password

  data_type: 'text'
  is_nullable: 0

=head2 emailonerror

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 type

  data_type: 'text'
  default_value: 'hydra'
  is_nullable: 0

=head2 publicdashboard

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "username",
  { data_type => "text", is_nullable => 0 },
  "fullname",
  { data_type => "text", is_nullable => 1 },
  "emailaddress",
  { data_type => "text", is_nullable => 0 },
  "password",
  { data_type => "text", is_nullable => 0 },
  "emailonerror",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "type",
  { data_type => "text", default_value => "hydra", is_nullable => 0 },
  "publicdashboard",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</username>

=back

=cut

__PACKAGE__->set_primary_key("username");

=head1 RELATIONS

=head2 newsitems

Type: has_many

Related object: L<Hydra::Schema::NewsItems>

=cut

__PACKAGE__->has_many(
  "newsitems",
  "Hydra::Schema::NewsItems",
  { "foreign.author" => "self.username" },
  undef,
);

=head2 projectmembers

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "projectmembers",
  "Hydra::Schema::ProjectMembers",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects_2s

Type: has_many

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->has_many(
  "projects_2s",
  "Hydra::Schema::Projects",
  { "foreign.owner" => "self.username" },
  undef,
);

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::StarredJobs",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 userroles

Type: has_many

Related object: L<Hydra::Schema::UserRoles>

=cut

__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::UserRoles",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects

Type: many_to_many

Composing rels: L</projectmembers> -> project

=cut

__PACKAGE__->many_to_many("projects", "projectmembers", "project");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-02-06 12:22:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4/WZ95asbnGmK+nEHb4sLQ

use Crypt::Passphrase;
use Digest::SHA1 qw(sha1_hex);
use String::Compare::ConstantTime;

my %hint = (
    columns => [
        "fullname",
        "emailaddress",
        "username"
    ],
    relations => {
        userroles => "role"
    }
);

sub json_hint {
    return \%hint;
}

sub _authenticator() {
    my $authenticator = Crypt::Passphrase->new(
        encoder    => 'Argon2',
        validators => [
            (sub {
                my ($password, $hash) = @_;

                return String::Compare::ConstantTime::equals($hash, sha1_hex($password));
            })
        ],
    );

    return $authenticator;
}

sub check_password {
    my ($self, $password) = @_;

    my $authenticator = _authenticator();
    if ($authenticator->verify_password($password, $self->password)) {
        if ($authenticator->needs_rehash($self->password)) {
            $self->setPassword($password);
        }

        return 1;
    } else {
        return 0;
    }
}

sub setPassword {
    my ($self, $password) = @_;;

    $self->update({
        "password" => _authenticator()->hash_password($password),
    });
}

1;
