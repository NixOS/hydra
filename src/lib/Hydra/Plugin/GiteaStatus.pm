##
# Gitea status plugin
#
# Sends per-commit build status to Gitea repositories, filtered by
# jobs and jobset inputs.
#
# Configure like this:
#
# <giteastatus>
#     # Create one in Gitea at Settings -> Applications ->
#     # Manage Access Tokens -> Generate Token
#     token = 0000000000000000000000000000000000000000
#     # Regexes matching the jobs separated by whitespace
#     jobs = sandbox:.*:test sandbox:release:release
#     # Names of matching jobset inputs separated by whitespace
#     inputs = sandbox
# </giteastatus>

package Hydra::Plugin::GiteaStatus;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use List::Util qw(max);

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{giteastatus};
}

sub toGiteaState {
    my ($status, $buildStatus) = @_;
    if ($status == 0 || $status == 1) {
        return "pending";
    } elsif ($buildStatus == 0) {
        return "success";
    } elsif ($buildStatus == 3 || $buildStatus == 4 || $buildStatus == 8 || $buildStatus == 10 || $buildStatus == 11) {
        return "error";
    } else {
        return "failure";
    }
}

sub common {
    my ($self, $build, $dependents, $status) = @_;
    my $cfg = $self->{config}->{giteastatus};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $b ($build, @{$dependents}) {
        my $jobName = showJobName $b;
        my $evals = $build->jobsetevals;
        my $ua = LWP::UserAgent->new();

        foreach my $conf (@config) {
            next unless $jobName =~ /^$conf->{jobs}$/;
            # Don't send out "pending" status updates if the build is already finished
            next if $status != 2 && $b->finished == 1;

            my $token = $conf->{token};
            my $body = encode_json(
                    {
                        state => toGiteaState($status, $b->buildstatus),
                        target_url => "$baseurl/build/" . $b->id,
                        description => "Hydra build #" . $b->id . " of $jobName",
                        context => "Hydra " . $b->get_column('job'),
                    });

            my $inputs_cfg = $conf->{inputs};
            my @inputs = defined $inputs_cfg ? ref $inputs_cfg eq "ARRAY" ? @$inputs_cfg : ($inputs_cfg) : ();
            my %seen = map { $_ => {} } @inputs;
            while (my $eval = $evals->next) {
                foreach my $input (@inputs) {
                    my $i = $eval->jobsetevalinputs->find({ name => $input, altnr => 0 });
                    next unless defined $i;
                    my $uri = $i->uri;
                    my $rev = $i->revision;
                    my $key = $uri . "-" . $rev;
                    next if exists $seen{$input}->{$key};
                    $seen{$input}->{$key} = 1;
                    $uri =~ m!^([^:]+://[^/]+)/([^/]+)/([^/]+?)(?:.git)?$!;
                    my $baseUrl = $1;
                    my $owner = $2;
                    my $repo = $3;
                    print STDERR "[GiteaStatus] POST $baseUrl/api/v1/repos/$owner/$repo/statuses/$rev?token=...\n";
                    my $url = "$baseUrl/api/v1/repos/$owner/$repo/statuses/$rev?token=$token";
                    my $req = HTTP::Request->new('POST', $url);
                    $req->header('Content-Type' => 'application/json');
                    $req->content($body);
                    my $res = $ua->request($req);
                    print STDERR "[GiteaStatus] ", $res->status_line, ": ", $res->decoded_content, "\n" unless $res->is_success;
                }
            }
        }
    }
}

sub buildQueued {
    common(@_, [], 0);
}

sub buildStarted {
    common(@_, [], 1);
}

sub buildFinished {
    common(@_, 2);
}

1;
