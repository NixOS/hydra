package Hydra::Plugin::MicrosoftTeamsNotification;

use strict;
use parent 'Hydra::Plugin';
use Hydra::Plugin::RichMessengerNotificationBase;

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $appType = Hydra::Plugin::RichMessengerNotificationBase->APP_MSTEAMS
    Hydra::Plugin::RichMessengerNotificationBase->buildFinished($self, $build, $dependents, $appType)
}

1;
