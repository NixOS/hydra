use strict;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Catalyst's default password checking is not constant time. To improve
# the security of the system, we replaced the check password routine.
# Verify comparing correct and incorrect passwords work.

# Starting the user with a sha1 password
my $user = $db->resultset('Users')->create({
    "username" => "alice",
    "emailaddress" => 'alice@nixos.org',
    "password" => "8843d7f92416211de9ebb963ff4ce28125932878" # SHA1 of "foobar"
});
isnt($user, undef, "My user was created.");

ok(!$user->check_password("barbaz"), "Checking the password, barbaz, is not right");
ok($user->check_password("foobar"), "Checking the password, foobar, is right");

done_testing;
