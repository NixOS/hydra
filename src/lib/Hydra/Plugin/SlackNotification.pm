package Hydra::Plugin::SlackNotification;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use JSON;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{slack};
}

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

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $cfg = $self->{config}->{slack};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

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

    return if scalar keys %channels == 0;

    my ($authors, $nrCommits) = getResponsibleAuthors($build, $self->{plugins});

    # Send a message to each room.
    foreach my $url (keys %channels) {
        my $channel = $channels{$url};
        my @deps = grep { $_->id != $build->id } @{$channel->{builds}};

        my $imgBase = "http://hydra.nixos.org";
        my $img =
            $build->buildstatus == 0 ? "$imgBase/static/images/checkmark_256.png" :
            $build->buildstatus == 2 ? "$imgBase/static/images/dependency_256.png" :
            $build->buildstatus == 4 ? "$imgBase/static/images/cancelled_128.png" :
            "$imgBase/static/images/error_256.png";

        my $color =
            $build->buildstatus == 0 ? "good" :
            $build->buildstatus == 4 ? "warning" :
            "danger";

        my $text = "";
        $text .= "Job <$baseurl/job/${\$build->get_column('project')}/${\$build->get_column('jobset')}/${\$build->get_column('job')}|${\showJobName($build)}>";
        $text .= " (and ${\scalar @deps} others)" if scalar @deps > 0;
        $text .= ": <$baseurl/build/${\$build->id}|" . showStatus($build) . ">". " in " . renderDuration($build);

        if (scalar keys %{$authors} > 0) {
            # FIXME: escaping
            my @x = map { "<mailto:$authors->{$_}|$_>" } (sort keys %{$authors});
            $text .= ", likely due to ";
            $text .= "$nrCommits commits by " if $nrCommits > 1;
            $text .= join(" or ", scalar @x > 1 ? join(", ", @x[0..scalar @x - 2]) : (), $x[-1]);
        }

        my $msg =
        { attachments =>
          [{ fallback => "Job " . showJobName($build) . " build number " . $build->id . ": " . showStatus($build),
            text => $text,
            thumb_url => $img,
            color => $color,
            title => "Job " . showJobName($build) . " build number " . $build->id,
            title_link => "$baseurl/build/${\$build->id}"
          }]
        };

        my $req = HTTP::Request->new('POST', $url);
        $req->header('Content-Type' => 'application/json');
        $req->content(encode_json($msg));
        my $ua = LWP::UserAgent->new();
        $ua->request($req);
    }
}

1;
