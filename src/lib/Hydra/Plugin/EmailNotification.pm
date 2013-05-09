package Hydra::Plugin::EmailNotification;

use strict;
use parent 'Hydra::Plugin';
use feature qw/switch/;
use POSIX qw(strftime);
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Email::Simple;
use Email::Simple::Creator;
use Sys::Hostname::Long;
use File::Slurp;
use Template;
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub showStatus {
    my ($build) = @_;

    my $status = "Failed";
    given ($build->buildstatus) {
        when (0) { $status = "Success"; }
        when (1) { $status = "Failed with non-zero exit code"; }
        when (2) { $status = "Dependency failed"; }
        when (4) { $status = "Cancelled"; }
    }

   return $status;
}


sub showJobName {
    my ($build) = @_;
    return $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;
}


sub getPrevBuild {
    my ($self, $build) = @_;
    return $self->{db}->resultset('Builds')->search(
        { project => $build->project->name
        , jobset => $build->jobset->name
        , job => $build->job->name
        , system => $build->system
        , finished => 1
        , id => { '<', $build->id }
        , -not => { buildstatus => { -in => [4, 3]} }
        }, { order_by => ["id DESC"], rows => 1 }
        )->single;
}


my $template = <<EOF;
Hi,

The status of Hydra job [% showJobName(build) %] (on [% build.system %]) [% IF prevBuild && build.buildstatus != prevBuild.buildstatus %]has changed from "[% showStatus(prevBuild) %]" to "[% showStatus(build) %]"[% ELSE %]is "[% showStatus(build) %]"[% END %].  For details, see

  [% baseurl %]/build/[% build.id %]

[% IF dependents.size > 0 -%]
The following dependent jobs also failed:

[% FOREACH b IN dependents -%]
* [% showJobName(b) %] ([% baseurl %]/build/[% b.id %])
[% END -%]

[% END -%]
[% IF build.buildstatus == 0 -%]
Yay!
[% ELSE -%]
Go forth and fix [% IF dependents.size == 0 -%]it[% ELSE %]them[% END %].
[% END -%]

Regards,

The Hydra build daemon.
EOF


sub buildFinished {
    my ($self, $build, $dependents) = @_;

    die unless $build->finished;

    # Figure out to whom to send notification for each build.  For
    # each email address, we send one aggregate email listing only the
    # relevant builds for that address.
    my %addresses;
    foreach my $b ($build, @{$dependents}) {
        my $prevBuild = getPrevBuild($self, $b);
        my $to = $b->jobset->emailoverride ne "" ? $b->jobset->emailoverride : $b->maintainers;

        foreach my $address (split ",", $to) {
            $address = trim $address;

            # Do we want to send mail for this build?
            unless ($ENV{'HYDRA_FORCE_SEND_MAIL'}) {
                next unless $b->jobset->enableemail;

                # If build is cancelled or aborted, do not send email.
                next if $b->buildstatus == 4 || $b->buildstatus == 3;

                # If there is a previous (that is not cancelled or aborted) build
                # with same buildstatus, do not send email.
                next if defined $prevBuild && ($b->buildstatus == $prevBuild->buildstatus);
            }

            $addresses{$address} //= { builds => [] };
            push @{$addresses{$address}->{builds}}, $b;
        }
    }

    # Send an email to each interested address.
    # !!! should use the Template Toolkit here.

    for my $to (keys %addresses) {
        print STDERR "sending mail notification to ", $to, "\n";
        my @builds = @{$addresses{$to}->{builds}};

        my $tt = Template->new({});

        my $vars =
            { build => $build, prevBuild => getPrevBuild($self, $build)
            , dependents => [grep { $_->id != $build->id } @builds]
            , baseurl => $self->{config}->{'base_uri'} || "http://localhost:3000"
            , showJobName => \&showJobName, showStatus => \&showStatus
            };

        my $body;
        $tt->process(\$template, $vars, \$body)
            or die "failed to generate email from template";

        # stripping trailing spaces from lines
        $body =~ s/[\ ]+$//gm;

        print "$body\n";

        my $sender = $self->{config}->{'notification_sender'} ||
            (($ENV{'USER'} || "hydra") .  "@" . hostname_long);

        #my $loglines = 50;
        #my $logtext = logContents($build->drvpath, $loglines);
        #$logtext = removeAsciiEscapes($logtext);

        my $email = Email::Simple->create(
            header => [
                To      => $to,
                From    => "Hydra Build Daemon <$sender>",
                Subject => showStatus($build) . ": Hydra job " . showJobName($build) . " on " . $build->system,
                'X-Hydra-Instance' => $vars->{baseurl},
                'X-Hydra-Project'  => $build->project->name,
                'X-Hydra-Jobset'   => $build->jobset->name,
                'X-Hydra-Job'      => $build->job->name,
                'X-Hydra-System'   => $build->system
            ],
            body => "",
        );
        $email->body_set($body);

        if (defined $ENV{'HYDRA_MAIL_SINK'}) {
            # For testing, redirect all mail to a file.
            write_file($ENV{'HYDRA_MAIL_SINK'}, { append => 1 }, $email->as_string . "\n");
        } else {
            sendmail($email);
        }
    }
}


1;
