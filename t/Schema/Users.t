use strict;
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
my $user = $db->resultset('Users')->create({
    "username" => "alice",
    "emailaddress" => 'alice@nixos.org',
    "password" => "8843d7f92416211de9ebb963ff4ce28125932878" # SHA1 of "foobar"
});
isnt($user, undef, "My user was created.");

ok(!$user->check_password("barbaz"), "Checking the password, barbaz, is not right");

is($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The unsalted sha1 is in the database.");
ok($user->check_password("foobar"), "Checking the password, foobar, is right");
isnt($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The user has had their password rehashed.");
ok($user->check_password("foobar"), "Checking the password, foobar, is still right");

done_testing;
