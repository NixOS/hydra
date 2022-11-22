use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Hydra::Helper::Exec;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

subtest "hydra-init upgrades user's password hashes from sha1 to sha1 inside Argon2" => sub {
    my $alice = $db->resultset('Users')->create({
        "username" => "alice",
        "emailaddress" => 'alice@nixos.org',
        "password" => "8843d7f92416211de9ebb963ff4ce28125932878" # SHA1 of "foobar"
    });
    my $janet = $db->resultset('Users')->create({
        "username" => "janet",
        "emailaddress" => 'janet@nixos.org',
        "password" => "!"
    });
    $janet->setPassword("foobar");

    is($alice->password, "8843d7f92416211de9ebb963ff4ce28125932878", "Alices's sha1 is stored in the database");
    my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-init"));
    if ($res != 0) {
        is($stdout, "");
        is($stderr, "");
    }
    is($res, 0, "hydra-init should exit zero");

    subtest "Alice had their password updated in place" => sub {
        my $updatedAlice = $db->resultset('Users')->find({ username => "alice" });
        isnt($updatedAlice, undef);
        isnt($updatedAlice->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The password was updated in place.");

        my $storedPassword = $updatedAlice->password;
        ok($updatedAlice->check_password("foobar"), "Their password validates");
        isnt($storedPassword, $updatedAlice->password, "The password is upgraded in place.");
    };

    subtest "Janet did not have their password change" => sub {
        my $updatedJanet = $db->resultset('Users')->find({ username => "janet" });
        isnt($updatedJanet, undef);
        is($updatedJanet->password, $janet->password, "The password was not updated in place.");

        ok($updatedJanet->check_password("foobar"), "Their password validates");
        is($updatedJanet->password, $janet->password, "The password is not upgraded in place.");
    };

    subtest "Running hydra-init don't break Alice or Janet's passwords" => sub {
        my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-init"));
        is($res, 0, "hydra-init should exit zero");

        my $updatedAlice = $db->resultset('Users')->find({ username => "alice" });
        ok($updatedAlice->check_password("foobar"), "Alice's password validates");

        my $updatedJanet = $db->resultset('Users')->find({ username => "janet" });
        ok($updatedJanet->check_password("foobar"), "Janet's password validates");
    };

};

done_testing;
