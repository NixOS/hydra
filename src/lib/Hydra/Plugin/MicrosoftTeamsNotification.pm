package Hydra::Plugin::MicrosoftTeamsNotification;

use strict;
use parent 'Hydra::Plugin::RichMessengerNotification';
use JSON;

sub getCfgForAppType {
    my ($self) = @_;
    return $self->{config}->{APP_MSTEAMS};
}

sub createTextLink {
    my ($linkUrl, $visibleText) = @_;
    # Markdown format
    return "[$visibleText]($linkUrl)"
}

sub createMessageJSON {
    my ($baseurl, $build, $text, $img, $color) = @_;
    my $title = "Job " . showJobName($build) . " build number " . $build->id
    my $buildLink = "$baseurl/build/${\$build->id}";
    my $fallbackMessage = $title . ": " . showStatus($build)

    return {
      '@type' => "MessageCard",
      '@context' => "http://schema.org/extensions",
      summary => $fallbackMessage,
      sections => [
        { 
          activityTitle => $title,
          activitySubtitle => createTextLink($appType, $buildLink, $buildLink),
          activityText => $text,
          activityImage => $img
        }
      ]
    };
}
