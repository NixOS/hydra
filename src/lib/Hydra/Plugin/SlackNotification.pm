package Hydra::Plugin::SlackNotification;

use strict;
use parent 'Hydra::Plugin::RichMessengerNotification';
use JSON;

sub getCfgForAppType {
    my ($self) = @_;
    return $self->{config}->{APP_SLACK};
}

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

1;
