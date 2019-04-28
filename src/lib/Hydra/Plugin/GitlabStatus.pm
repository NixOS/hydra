package Hydra::Plugin::GitlabStatus;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use List::Util qw(max);

# This plugin expects as inputs to a jobset the following:
#   - gitlab_status_repo => Name of the repository input pointing to that
#     status updates should be POST'ed, i.e. the jobset has a git input
#     "nixexprs": "https://gitlab.example.com/project/nixexprs", in which
#     case "gitlab_status_repo" would be "nixexprs".
#   - gitlab_project_id => ID of the project in Gitlab, i.e. in the above
#     case the ID in gitlab of "nixexprs"

sub toGitlabState {
    my ($status, $buildStatus) = @_;
    if ($status == 0) {
        return "pending";
    } elsif ($status == 1) {
        return "running";
    } elsif ($buildStatus == 0) {
        return "success";
    } elsif ($buildStatus == 3 || $buildStatus == 4 || $buildStatus == 8 || $buildStatus == 10 || $buildStatus == 11) {
        return "canceled";
    } else {
        return "failed";
    }
}

sub common {
    my ($self, $build, $dependents, $status) = @_;
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $b ($build, @{$dependents}) {
        my $jobName = showJobName $b;
        my $evals = $build->jobsetevals;
        my $ua = LWP::UserAgent->new();

        # Don't send out "pending/running" status updates if the build is already finished
        next if $status < 2 && $b->finished == 1;

        my $state = toGitlabState($status, $b->buildstatus);
        my $body = encode_json(
            {
                state => $state,
                target_url => "$baseurl/build/" . $b->id,
                description => "Hydra build #" . $b->id . " of $jobName",
                name => "Hydra " . $b->job->name,
            });
        while (my $eval = $evals->next) {
            my $gitlabstatusInput = $eval->jobsetevalinputs->find({ name => "gitlab_status_repo" });
            next unless defined $gitlabstatusInput->value;
            my $i = $eval->jobsetevalinputs->find({ name => $gitlabstatusInput->value, altnr => 0 });
            next unless defined $i;
            my $projectId = $eval->jobsetevalinputs->find({ name => "gitlab_project_id" })->value;
            my $accessToken = $self->{config}->{gitlab_authorization}->{$projectId};
            my $rev = $i->revision;
            my $domain = URI->new($i->uri)->host;
            my $url = "https://$domain/api/v4/projects/$projectId/statuses/$rev";
            print STDERR "GitlabStatus POSTing $state to $url\n";
            my $req = HTTP::Request->new('POST', $url);
            $req->header('Content-Type' => 'application/json');
            $req->header('Private-Token' => $accessToken);
            $req->content($body);
            my $res = $ua->request($req);
            print STDERR $res->status_line, ": ", $res->decoded_content, "\n" unless $res->is_success;
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
