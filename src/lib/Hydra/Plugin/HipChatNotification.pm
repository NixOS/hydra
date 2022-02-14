package Hydra::Plugin::HipChatNotification;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{hipchat};
}

sub buildFinished {
    my ($self, $topbuild, $dependents) = @_;

    my $cfg    = $self->{config}->{hipchat};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Figure out to which rooms to send notification.  For each email
    # room, we send one aggregate message.
    my %rooms;
    foreach my $build ($topbuild, @{$dependents}) {
        my $prevBuild = getPreviousBuild($build);
        my $jobName   = showJobName $build;

        foreach my $room (@config) {
            my $force = $room->{force};
            next unless $jobName =~ /^$room->{jobs}$/;

            # If build is cancelled or aborted, do not send email.
            next if !$force && ($build->buildstatus == 4 || $build->buildstatus == 3);

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send email.
            next if !$force && defined $prevBuild && ($build->buildstatus == $prevBuild->buildstatus);

            $rooms{ $room->{room} } //= { room => $room, builds => [] };
            push @{ $rooms{ $room->{room} }->{builds} }, $build;
        }
    }

    return if scalar keys %rooms == 0;

    my ($authors, $nrCommits) = getResponsibleAuthors($topbuild, $self->{plugins});

    # Send a message to each room.
    foreach my $roomId (keys %rooms) {
        my $room = $rooms{$roomId};
        my @deps = grep { $_->id != $topbuild->id } @{ $room->{builds} };

        my $img =
            $topbuild->buildstatus == 0 ? "$baseurl/static/images/checkmark_16.png"
          : $topbuild->buildstatus == 2 ? "$baseurl/static/images/dependency_16.png"
          : $topbuild->buildstatus == 4 ? "$baseurl/static/images/cancelled_16.png"
          :                               "$baseurl/static/images/error_16.png";

        my $msg = "";
        $msg .= "<img src='$img'/> ";
        $msg .=
"Job <a href='$baseurl/job/${\$topbuild->jobset->get_column('project')}/${\$topbuild->jobset->get_column('name')}/${\$topbuild->get_column('job')}'>${\showJobName($topbuild)}</a>";
        $msg .= " (and ${\scalar @deps} others)" if scalar @deps > 0;
        $msg .= ": <a href='$baseurl/build/${\$topbuild->id}'>" . showStatus($topbuild) . "</a>";

        if (scalar keys %{$authors} > 0) {

            # FIXME: HTML escaping
            my @x = map { "<a href='mailto:$authors->{$_}'>$_</a>" } (sort keys %{$authors});
            $msg .= ", likely due to ";
            $msg .= "$nrCommits commits by " if $nrCommits > 1;
            $msg .= join(" or ", scalar @x > 1 ? join(", ", @x[ 0 .. scalar @x - 2 ]) : (), $x[-1]);
        }

        print STDERR "sending hipchat notification to room $roomId: $msg\n";

        my $ua   = LWP::UserAgent->new();
        my $resp = $ua->post(
            'https://api.hipchat.com/v1/rooms/message?format=json&auth_token=' . $room->{room}->{token},
            {
                room_id        => $roomId,
                from           => 'Hydra',
                message        => $msg,
                message_format => 'html',
                notify         => $room->{room}->{notify} || 0,
                color          => $topbuild->buildstatus == 0 ? 'green' : 'red'
            }
        );

        print STDERR $resp->status_line, ": ", $resp->decoded_content, "\n" if !$resp->is_success;
    }
}

1;
