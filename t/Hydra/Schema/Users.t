use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Hydra used to store passwords, by default, as plain unsalted sha1 hashes.
# We now upgrade these badly stored passwords with much stronger algorithms
# when the user logs in. Implementing this meant reimplementing our password
# checking ourselves, so also ensure that basic password checking works.
#
# This test:
#
# 1. creates a user with the legacy password
# 2. validates that the wrong password is not considered valid
# 3. validates that the correct password is valid
# 4. checks that the checking of the correct password transparently upgraded
#    the password's storage to a more secure algorithm.

# Starting the user with an unsalted sha1 password
my $user = $db->resultset('Users')->create(
    {
        "username"     => "alice",
        "emailaddress" => 'alice@nixos.org',
        "password"     => "8843d7f92416211de9ebb963ff4ce28125932878"    # SHA1 of "foobar"
    }
);
isnt($user, undef, "My user was created.");

ok(!$user->check_password("barbaz"), "Checking the password, barbaz, is not right");

is($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The unsalted sha1 is in the database.");
ok($user->check_password("foobar"), "Checking the password, foobar, is right");
isnt($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The user has had their password rehashed.");
ok($user->check_password("foobar"), "Checking the password, foobar, is still right");

# All sha1 passwords will be upgraded when `hydra-init` is run, by passing the sha1 through
# Argon2. Verify a rehashed sha1 validates too. This removes very weak password hashes
# from the database without requiring users to log in.
subtest "Hashing their sha1 as Argon2 still lets them log in with their password" => sub {
    $user->setPassword("8843d7f92416211de9ebb963ff4ce28125932878");    # SHA1 of "foobar"
    my $hashedHashPassword = $user->password;
    isnt(
        $user->password,
        "8843d7f92416211de9ebb963ff4ce28125932878",
        "The user has had their password's hash rehashed."
    );
    ok($user->check_password("foobar"), "Checking the password, foobar, is still right");
    isnt($user->password, $hashedHashPassword, "The user's hashed hash was replaced with just Argon2.");
};

subtest "Setting the user's passwordHash to a sha1 stores the password as a hashed sha1" => sub {
    $user->setPasswordHash("8843d7f92416211de9ebb963ff4ce28125932878");
    isnt($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The password was not saved in plain text.");

    my $storedPassword = $user->password;
    ok($user->check_password("foobar"), "Their password validates");
    isnt($storedPassword, $user->password, "The password was upgraded.");
};

subtest "Setting the user's passwordHash to an argon2 password stores the password as given" => sub {
    $user->setPasswordHash('$argon2id$v=19$m=262144,t=3,p=1$tMnV5paYjmIrUIb6hylaNA$M8/e0i3NGrjhOliVLa5LqQ');
    isnt($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The password was not saved in plain text.");
    is(
        $user->password,
        '$argon2id$v=19$m=262144,t=3,p=1$tMnV5paYjmIrUIb6hylaNA$M8/e0i3NGrjhOliVLa5LqQ',
        "The password was saved as-is."
    );

    my $storedPassword = $user->password;
    ok($user->check_password("foobar"), "Their password validates");
    is($storedPassword, $user->password, "The password was not upgraded.");
};
done_testing;
