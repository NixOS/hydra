use utf8;
package Hydra::Schema::Result::Users;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::Users

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

Related object: L<Hydra::Schema::Result::NewsItems>

=cut

__PACKAGE__->has_many(
  "newsitems",
  "Hydra::Schema::Result::NewsItems",
  { "foreign.author" => "self.username" },
  undef,
);

=head2 projectmembers

Type: has_many

Related object: L<Hydra::Schema::Result::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "projectmembers",
  "Hydra::Schema::Result::ProjectMembers",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects_2s

Type: has_many

Related object: L<Hydra::Schema::Result::Projects>

=cut

__PACKAGE__->has_many(
  "projects_2s",
  "Hydra::Schema::Result::Projects",
  { "foreign.owner" => "self.username" },
  undef,
);

=head2 starredjobs

Type: has_many

Related object: L<Hydra::Schema::Result::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starredjobs",
  "Hydra::Schema::Result::StarredJobs",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 userroles

Type: has_many

Related object: L<Hydra::Schema::Result::UserRoles>

=cut

__PACKAGE__->has_many(
  "userroles",
  "Hydra::Schema::Result::UserRoles",
  { "foreign.username" => "self.username" },
  undef,
);

=head2 projects

Type: many_to_many

Composing rels: L</projectmembers> -> project

=cut

__PACKAGE__->many_to_many("projects", "projectmembers", "project");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-08-26 12:02:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:qePTzHYl/TjCSjZrU2g/cg

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
        encoder    => { module => 'Argon2', output_size => 16 },
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
    } elsif ($authenticator->verify_password(sha1_hex($password), $self->password)) {
        # The user's database record has their old password as sha1, re-hashed as Argon2.
        # Store their password hashed only with Argon2.
        $self->setPassword($password);

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

sub setPasswordHash {
    my ($self, $passwordHash) = @_;;

    if ($passwordHash =~ /^[a-f0-9]{40}$/) {
        # This is (probably) a sha1 password, re-hash it and we'll check for a hashed sha1 in Users.pm
        $self->setPassword($passwordHash);
    } else {
        $self->update({ password => $passwordHash });
    }
}

1;
