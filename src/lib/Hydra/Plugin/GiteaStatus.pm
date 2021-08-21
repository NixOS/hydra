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
    return defined $self->{config}->{gitea_authorization};
}

sub toGiteaState {
    # See https://try.gitea.io/api/swagger#/repository/repoCreateStatus
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
    my ($self, $topbuild, $dependents, $status) = @_;
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $build ($topbuild, @{$dependents}) {
        my $jobName = showJobName $build;
        my $evals = $topbuild->jobsetevals;
        my $ua = LWP::UserAgent->new();

        # Don't send out "pending/running" status updates if the build is already finished
        next if $status < 2 && $build->finished == 1;

        my $state = toGiteaState($status, $build->buildstatus);
        my $body = encode_json(
            {
                state => $state,
                target_url => "$baseurl/build/" . $build->id,
                description => "Hydra build #" . $build->id . " of $jobName",
                context => "Hydra " . $build->get_column('job'),
            });

        while (my $eval = $evals->next) {
            my $giteastatusInput = $eval->jobsetevalinputs->find({ name => "gitea_status_repo" });
            next unless defined $giteastatusInput && defined $giteastatusInput->value;
            my $i = $eval->jobsetevalinputs->find({ name => $giteastatusInput->value, altnr => 0 });
            next unless defined $i;
            my $gitea_url = $eval->jobsetevalinputs->find({ name => "gitea_http_url" });

            my $repoOwner = $eval->jobsetevalinputs->find({ name => "gitea_repo_owner" })->value;
            my $repoName = $eval->jobsetevalinputs->find({ name => "gitea_repo_name" })->value;
            my $accessToken = $self->{config}->{gitea_authorization}->{$repoOwner};

            my $rev = $i->revision;
            my $domain = URI->new($i->uri)->host;
            my $host;
            unless (defined $gitea_url) {
                $host = "https://$domain";
            } else {
                $host = $gitea_url->value;
            }

            my $url = "$host/api/v1/repos/$repoOwner/$repoName/statuses/$rev";

            print STDERR "GiteaStatus POSTing $state to $url\n";
            my $req = HTTP::Request->new('POST', $url);
            $req->header('Content-Type' => 'application/json');
            $req->header('Authorization' => "token $accessToken");
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
