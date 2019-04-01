package Hydra::Plugin::SlackNotification;

use strict;
use parent 'Hydra::Plugin';
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Notification;
use JSON;

# TODO: refactor to reduce duplicate code with MicrosoftTeamsNotification.pm

sub createTextLink {
    my ($linkUrl, $visibleText) = @_;
    return "<$linkUrl|$visibleText>"
}

sub createMessageJSON {
    my ($baseurl, $build, $text, $img, $color) = @_;
    my $title = "Job " . showJobName($build) . " build number " . $build->id
    my $buildLink = "$baseurl/build/${\$build->id}";
    my $fallbackMessage = $title . ": " . showStatus($build)

    return { 
      attachments => [
        {
          fallback => $fallbackMessage,
          text => $text,
          thumb_url => $img,
          color => $color,
          title => $title,
          title_link => $buildLink
        }
      ]
    };
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $cfg = $self->{config}->{slack};

    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Figure out to which channelss to send notification.  For each channel
    # we send one aggregate message.
    my %channels = getChannelsToNotify($build, $dependents, $cfg);
    return if scalar keys %channels == 0;

    my ($authors, $nrCommits) = getResponsibleAuthors($build, $self->{plugins});

    # Send a message to each room.
    foreach my $url (keys %channels) {
        my $channel = $channels{$url};
        my @deps = grep { $_->id != $build->id } @{$channel->{builds}};

        my $img = selectImage($build);
        my $color = selectColor($build);

        my $text = "";
        $text .= "Job " . createTextLink("$baseurl/job/${\$build->project->name}/${\$build->jobset->name}/${\$build->job->name}", showJobName($build));
        $text .= " (and ${\scalar @deps} others)" if scalar @deps > 0;
        $text .= ": " . createTextLink("$baseurl/build/${\$build->id}", showStatus($build)) . " in " . renderDuration($build);

        if (scalar keys %{$authors} > 0) {
            # FIXME: escaping
            my @x = map { createTextLink("mailto:$authors->{$_}", $_) } (sort keys %{$authors});
            $text .= ", likely due to ";
            $text .= "$nrCommits commits by " if $nrCommits > 1;
            $text .= join(" or ", scalar @x > 1 ? join(", ", @x[0..scalar @x - 2]) : (), $x[-1]);
        }

        my $msg = createMessageJSON($baseurl, $build, $text, $img, $color);

        sendMessage($url, $msg);
    }
}

1;
