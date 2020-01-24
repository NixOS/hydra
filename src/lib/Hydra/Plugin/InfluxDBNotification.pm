package Hydra::Plugin::InfluxDBNotification;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
# use JSON;
use LWP::UserAgent;
# use Hydra::Helper::CatalystUtils;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{influxdb};
}

sub toBuildStatusDetailed {
    my ($buildStatus) = @_;
    if ($buildStatus == 0) {
        return "success";
    }
    elsif ($buildStatus == 1) {
        return "failure";
    }
    elsif ($buildStatus == 2) {
        return "dependency-failed";
    }
    elsif ($buildStatus == 4) {
        return "cancelled";
    }
    elsif ($buildStatus == 6) {
        return "failed-with-output";
    }
    elsif ($buildStatus == 7) {
        return "timed-out";
    }
    elsif ($buildStatus == 9) {
        return "unsupported-system";
    }
    elsif ($buildStatus == 10) {
        return "log-limit-exceeded";
    }
    elsif ($buildStatus == 11) {
        return "output-limit-exceeded";
    }
    elsif ($buildStatus == 12) {
        return "non-deterministic-build";
    }
    else {
        return "aborted";
    }
}

sub toBuildStatusClass {
    my ($buildStatus) = @_;
    if ($buildStatus == 0) {
        return "success";
    }
    elsif ($buildStatus == 3
        || $buildStatus == 4
        || $buildStatus == 8
        || $buildStatus == 10
        || $buildStatus == 11)
    {
        return "canceled";
    }
    else {
        return "failed";
    }
}

# Syntax
# build_status,job=my-job status=failed,result=dependency-failed duration=123i
#   |    -------------------- --------------  |
#   |             |             |             |
#   |             |             |             |
#   +-----------+--------+-+---------+-+---------+
#   |measurement|,tag_set| |field_set| |timestamp|
#   +-----------+--------+-+---------+-+---------+
sub createLine {
    my ($measurement, $tagSet, $fieldSet, $timestamp) = @_;
    my @tags = ();
    foreach my $tag (sort keys %$tagSet) {
        push @tags, "$tag=$tagSet->{$tag}";
    }
    my @fields = ();
    foreach my $field (sort keys %$fieldSet) {
        push @fields, "$field=$fieldSet->{$field}";
    }
    my $tags   = join(",", @tags);
    my $fields = join(",", @fields);
    return "$measurement,$tags $fields $timestamp";
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $influxdb = $self->{config}->{influxdb};

    # skip if we didn't configure
    return unless defined $influxdb;
    # skip if we didn't set the URL and the DB
    return unless ref $influxdb eq 'HASH' and exists $influxdb->{url} and exists $influxdb->{db};

    my @lines = ();
    foreach my $b ($build, @{$dependents}) {
        my $tagSet = {
            status  => toBuildStatusClass($b->buildstatus),
            result  => toBuildStatusDetailed($b->buildstatus),
            project => $b->get_column('project'),
            jobset  => $b->get_column('jobset'),
            repo    => ($b->get_column('jobset') =~ /^(.*)\.pr-/) ? $1 : $b->get_column('jobset'),
            job     => $b->get_column('job'),
            system  => $b->system,
            cached  => $b->iscachedbuild ? "true" : "false",
        };
        my $fieldSet = {
            # this line is needed to be able to query the statuses
            build_status  => $b->buildstatus . "i",
            build_id      => '"' . $b->id . '"',
            main_build_id => '"' . $build->id . '"',
            duration      => ($b->stoptime - $b->starttime) . "i",
            queued        => ($b->starttime - $b->timestamp > 0 ? $b->starttime - $b->timestamp : 0) . "i",
            closure_size  => ($b->closuresize // 0) . "i",
            size          => ($b->size // 0) . "i",
        };
        my $line =
          createLine("hydra_build_status", $tagSet, $fieldSet, $b->stoptime);
        push @lines, $line;
    }

    my $payload = join("\n", @lines);
    print STDERR "sending InfluxDB measurements to server $influxdb->{url}:\n$payload\n";

    my $ua  = LWP::UserAgent->new();
    my $req = HTTP::Request->new('POST',
        "$influxdb->{url}/write?db=$influxdb->{db}&precision=s");
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->content($payload);
    my $res = $ua->request($req);
    print STDERR $res->status_line, ": ", $res->decoded_content, "\n"
      unless $res->is_success;
}

1;
