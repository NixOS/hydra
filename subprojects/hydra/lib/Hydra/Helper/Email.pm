package Hydra::Helper::Email;

use strict;
use warnings;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Exporter 'import';
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
        # For testing, redirect all mail to a file. Appended, because a run
        # sends more than one message and every sender opens this separately;
        # in one write, so that two of them cannot interleave a message.
        my $sink = $ENV{'HYDRA_MAIL_SINK'};
        open(my $fh, ">>", $sink) or die "cannot append to `$sink': $!\n";
        print $fh $email->as_string . "\n";
        close($fh) or die "cannot write to `$sink': $!\n";
    } else {
        sendmail($email, { from => $sender });
    }
}

1;
