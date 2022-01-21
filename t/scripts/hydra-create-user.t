use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();
my $db = $ctx->db();

subtest "Handling password and password hash creation" => sub {
    subtest "Creating a user with a plain text password (insecure) stores the password securely" => sub {
        my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-create-user", "plain-text-user", "--password", "foobar"));
        is($res, 0, "hydra-create-user should exit zero");

        my $user = $db->resultset('Users')->find({ username => "plain-text-user" });
        isnt($user, undef, "The user exists");
        isnt($user->password, "foobar", "The password was not saved in plain text.");

        my $storedPassword = $user->password;
        ok($user->check_password("foobar"), "Their password validates");
        is($storedPassword, $user->password, "The password was not upgraded.");
    };

    subtest "Creating a user with a sha1 password (still insecure) stores the password as a hashed sha1" => sub {
        my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-create-user", "old-password-hash-user", "--password-hash", "8843d7f92416211de9ebb963ff4ce28125932878"));
        is($res, 0, "hydra-create-user should exit zero");

        my $user = $db->resultset('Users')->find({ username => "old-password-hash-user" });
        isnt($user, undef, "The user exists");
        isnt($user->password, "8843d7f92416211de9ebb963ff4ce28125932878", "The password was not saved in plain text.");

        my $storedPassword = $user->password;
        ok($user->check_password("foobar"), "Their password validates");
        isnt($storedPassword, $user->password, "The password was upgraded.");
    };

    subtest "Creating a user with an argon2 password stores the password as given" => sub {
        my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-create-user", "argon2-hash-user", "--password-hash", '$argon2id$v=19$m=262144,t=3,p=1$tMnV5paYjmIrUIb6hylaNA$M8/e0i3NGrjhOliVLa5LqQ'));
        is($res, 0, "hydra-create-user should exit zero");

        my $user = $db->resultset('Users')->find({ username => "argon2-hash-user" });
        isnt($user, undef, "The user exists");
        is($user->password, '$argon2id$v=19$m=262144,t=3,p=1$tMnV5paYjmIrUIb6hylaNA$M8/e0i3NGrjhOliVLa5LqQ', "The password was saved as-is.");

        my $storedPassword = $user->password;
        ok($user->check_password("foobar"), "Their password validates");
        is($storedPassword, $user->password, "The password was not upgraded.");
    };

    subtest "Creating a user by prompting for the password" => sub {
        subtest "with the same password twice" => sub {
            my ($res, $stdout, $stderr) = captureStdoutStderrWithStdin(5, ["hydra-create-user", "prompted-pass-user", "--password-prompt"], "my-password\nmy-password\n");
            is($res, 0, "hydra-create-user should exit zero");

            my $user = $db->resultset('Users')->find({ username => "prompted-pass-user" });
            isnt($user, undef, "The user exists");
            like($user->password, qr/^\$argon2id\$v=/, "The password was saved, hashed with argon2id.");

            my $storedPassword = $user->password;
            ok($user->check_password("my-password"), "Their password validates");
        };

        subtest "With mismatched password confirmation" => sub {
            my ($res, $stdout, $stderr) = captureStdoutStderrWithStdin(5, ["hydra-create-user", "prompted-pass-user", "--password-prompt"], "my-password\nnot-my-password\n");
            isnt($res, 0, "hydra-create-user should exit non-zero");
        };
    };

    subtest "Specifying conflicting password options fails" => sub {
        my @cases = (
            [ "--password=foo", "--password-hash=8843d7f92416211de9ebb963ff4ce28125932878", "--password-prompt" ],
            [ "--password=foo", "--password-prompt" ],
            [ "--password=foo", "--password-hash=8843d7f92416211de9ebb963ff4ce28125932878" ],
            [ "--password-hash=8843d7f92416211de9ebb963ff4ce28125932878", "--password-prompt" ],
        );

        for my $case (@cases) {
            my ($res, $stdout, $stderr) = captureStdoutStderr(5, (
                "hydra-create-user", "bogus-password-options", @{$case}));
            like($stderr, qr/please specify one of --password-prompt or --password-hash/, "We get an error about specifying the password");
            isnt($res, 0, "hydra-create-user should exit non-zero with conflicting " . join(" ", @{$case}));
        }
    };

    subtest "A password is not required for creating a Google-based account" => sub {
        my ($res, $stdout, $stderr) = captureStdoutStderr(5, (
            "hydra-create-user", "google-account", "--type", "google"));
        is($res, 0, "hydra-create-user should exit zero");
    };
};

done_testing;
