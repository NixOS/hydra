package Hydra::Plugin::CircleCINotification;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use JSON;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{circleci};
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $cfg = $self->{config}->{circleci};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    # Figure out to which branches to send notification.
    my %branches;
    foreach my $b ($build, @{$dependents}) {
        my $prevBuild = getPreviousBuild($b);
        my $jobName = showJobName $b;

        foreach my $branch (@config) {
            my $force = $branch->{force};
            next unless $jobName =~ /^$branch->{jobs}$/;

            # If build is failed, don't trigger circleci
            next if ! $force && $b->buildstatus != 0;

            my $fullUrl = "https://circleci.com/api/v1.1/project/" . $branch->{vcstype} . "/" . $branch->{username} . "/" . $branch->{project} . "/tree/" . $branch->{branch} . "?circle-token=" . $branch->{token};
            $branches{$fullUrl} = 1;
        }
    }

    return if scalar keys %branches == 0;

    # Trigger earch branch
    my $ua = LWP::UserAgent->new();
    foreach my $url (keys %branches) {
        my $req = HTTP::Request->new('POST', $url);
        $req->header('Content-Type' => 'application/json');
        $ua->request($req);
    }
}

1;
