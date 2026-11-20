use strict;
use warnings;
use Setup;
use File::Temp qw(tempdir);

my $ctx = test_context();

require Hydra::Helper::Email;

use Test2::V0;

my $config = {
    notification_sender => 'hydra@example.org',
    base_uri => 'https://hydra.example.org',
};

# Clear whatever else would decide where the mail goes.
local $ENV{HYDRA_MAIL_SINK};
local $ENV{EMAIL_SENDER_TRANSPORT};
delete $ENV{HYDRA_MAIL_SINK};
delete $ENV{EMAIL_SENDER_TRANSPORT};

subtest "mail goes to the sendmail it is told of" => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Records its arguments, one per line, and the message.
    my $sendmail = "$dir/sendmail";
    open(my $fh, ">", $sendmail) or die "cannot write `$sendmail': $!";
    print $fh "#!/bin/sh\nprintf '%s\\n' \"\$@\" > '$dir/args'\ncat > '$dir/message'\n";
    close($fh);
    chmod(0755, $sendmail) or die "cannot chmod `$sendmail': $!";

    local $ENV{HYDRA_PROGRAM_SENDMAIL} = $sendmail;
    Hydra::Helper::Email::sendEmail($config, 'alice@example.org', "Hello", "Some body", []);

    open(my $args, "<", "$dir/args") or die "sendmail was not run: $!";
    my @args = map { chomp; $_ } <$args>;
    is(\@args, [ '-i', '-f', 'hydra@example.org', '--', 'alice@example.org' ],
        "sendmail is given the envelope");

    open(my $message, "<", "$dir/message") or die "sendmail was given no message: $!";
    my $text = do { local $/; <$message> };
    like($text, qr/^Subject: Hello\r?$/m, "sendmail is given the message");
    like($text, qr/^X-Hydra-Instance: https:\/\/hydra\.example\.org\r?$/m,
        "the message says which Hydra sent it");
};

subtest "no sendmail is looked for on PATH" => sub {
    local $ENV{HYDRA_PROGRAM_SENDMAIL};
    delete $ENV{HYDRA_PROGRAM_SENDMAIL};
    like(
        dies { Hydra::Helper::Email::sendEmail($config, 'alice@example.org', "Hello", "Some body", []) },
        qr/HYDRA_PROGRAM_SENDMAIL is not set/,
        "sending fails, naming the variable to set",
    );
};

done_testing;
