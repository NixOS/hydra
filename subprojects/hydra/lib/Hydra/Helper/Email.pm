package Hydra::Helper::Email;

use strict;
use warnings;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Exporter 'import';
use Hydra::Helper::Nix;
use Hydra::Config;
use Sys::Hostname::Long;
use Try::Tiny;

our @EXPORT = qw(sendEmail sendJobsetErrorNotification);

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


sub sendJobsetErrorNotification {
    my ($config, $jobset, $errorMsg) = @_;

    chomp $errorMsg;

    return unless evalEmailNotificationEnabled($config);
    return if $jobset->project->owner->emailonerror == 0;
    return if $errorMsg eq "";

    my $projectName = $jobset->get_column('project');
    my $jobsetName = $jobset->name;
    my $body = "Hi,\n"
        . "\n"
        . "This is to let you know that evaluation of the Hydra jobset ‘$projectName:$jobsetName’\n"
        . "resulted in the following error:\n"
        . "\n"
        . "$errorMsg"
        . "\n"
        . "Regards,\n\nThe Hydra build daemon.\n";

    try {
        sendEmail(
            $config,
            $jobset->project->owner->emailaddress,
            "Hydra $projectName:$jobsetName evaluation error",
            $body,
            [ 'X-Hydra-Project' => $projectName
            , 'X-Hydra-Jobset'  => $jobsetName
            ]);
    } catch {
        warn "error sending email: $_\n";
    };
}

1;
