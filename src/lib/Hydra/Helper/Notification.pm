package Hydra::Helper::Notification;

use strict;
use Exporter;
use HTTP::Request;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use JSON;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    renderDuration
    getChannelsToNotify
    selectImage
    selectColor
    sendMessage);

sub renderDuration {
    my ($build) = @_;
    my $duration = $build->stoptime - $build->starttime;
    my $res = "";
    if ($duration >= 24*60*60) {
       $res .= ($duration / (24*60*60)) . "d";
    }
    if ($duration >= 60*60) {
        $res .= (($duration / (60*60)) % 24) . "h";
    }
    if ($duration >= 60) {
        $res .= (($duration / 60) % 60) . "m";
    }
    $res .= ($duration % 60) . "s";
    return $res;
}


sub getChannelsToNotify {
    my ($build, $dependents, $cfg) = @_;

    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    # Figure out to which channelss to send notification.  For each channel
    # we send one aggregate message.
    my %channels;
    foreach my $b ($build, @{$dependents}) {
        my $prevBuild = getPreviousBuild($b);
        my $jobName = showJobName $b;

        foreach my $channel (@config) {
            my $force = $channel->{force};
            next unless $jobName =~ /^$channel->{jobs}$/;

            # If build is cancelled or aborted, do not send email.
            next if ! $force && ($b->buildstatus == 4 || $b->buildstatus == 3);

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send email.
            next if ! $force && defined $prevBuild && ($b->buildstatus == $prevBuild->buildstatus);

            $channels{$channel->{url}} //= { channel => $channel, builds => [] };
            push @{$channels{$channel->{url}}->{builds}}, $b;
        }
    }

    return %channels;
}

sub selectImage {
    my ($build) = @_;

    my $imgBase = "http://hydra.nixos.org";
    my $img =
        $build->buildstatus == 0 ? "$imgBase/static/images/checkmark_256.png" :
        $build->buildstatus == 2 ? "$imgBase/static/images/dependency_256.png" :
        $build->buildstatus == 4 ? "$imgBase/static/images/cancelled_128.png" :
        "$imgBase/static/images/error_256.png";

    return $img;
}

sub selectColor {
    my ($build) = @_;

    my $color =
        $build->buildstatus == 0 ? "good" :
        $build->buildstatus == 4 ? "warning" :
        "danger";

    return $color;
}

sub sendMessage {
    my ($url, $msg) = @_;

    my $req = HTTP::Request->new('POST', $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($msg));
    my $ua = LWP::UserAgent->new();
    $ua->request($req);
}

1;
