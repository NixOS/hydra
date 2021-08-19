package Hydra::Helper::Email;

use strict;
use warnings;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Exporter 'import';
use File::Slurp;
use Hydra::Helper::Nix;
use Sys::Hostname::Long;

our @EXPORT = qw(sendEmail);

sub sendEmail {
    my ($config, $to, $subject, $body, $extraHeaders) = @_;

    my $url = getBaseUrl($config);
    my $sender = $config->{'notification_sender'} // (($ENV{'USER'} // "hydra") .  "@" . hostname_long);

    my @headers = (
        To => $to,
        From => "Hydra Build Daemon <$sender>",
        Subject => $subject,
        'X-Hydra-Instance' => $url, @{$extraHeaders}
        );

    my $email = Email::MIME->create(
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        header_str => [ @headers ],
        body_str => $body
    );

    print STDERR "sending email:\n", $email->as_string if $ENV{'HYDRA_MAIL_TEST'};

    if (defined $ENV{'HYDRA_MAIL_SINK'}) {
        # For testing, redirect all mail to a file.
        write_file($ENV{'HYDRA_MAIL_SINK'}, { append => 1 }, $email->as_string . "\n");
    } else {
        sendmail($email, { from => $sender });
    }
}

1;
