package Hydra::Plugin::BitBucketStatus;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;

sub isEnabled {
    my ($self) = @_;
    return $self->{config}->{enable_bitbucket_status} == 1;
}

sub toBitBucketState {
    my ($buildStatus) = @_;
    if ($buildStatus == 0) {
        return "SUCCESSFUL";
    } else {
        return "FAILED";
    }
}

sub common {
    my ($self, $build, $dependents, $finished) = @_;
    my $bitbucket = $self->{config}->{bitbucket};
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    foreach my $b ($build, @{$dependents}) {
        my $jobName = showJobName $b;
        my $evals = $build->jobsetevals;
        my $ua = LWP::UserAgent->new();
        my $body = encode_json(
            {
                state => $finished ? toBitBucketState($b->buildstatus) : "INPROGRESS",
                url => "$baseurl/build/" . $b->id,
                name => $jobName,
                key => $b->id,
                description => "Hydra build #" . $b->id . " of $jobName",
            });
        while (my $eval = $evals->next) {
            foreach my $i ($eval->jobsetevalinputs){
                next unless defined $i;

                # Skip if the emailResponsible field is disabled
                my $input = $eval->jobset->jobsetinputs->find({name => $i->name });
                next unless $input->emailresponsible;

                my $uri = $i->uri;
                my $rev = $i->revision;
                # Skip if the uri is not a bitbucket repo
                next unless index($uri, 'bitbucket') != -1;
                $uri =~ m![:/]([^/]+)/([^/]+?)?$!;
                my $owner = $1;
                my $repo = $2;
                my $req = HTTP::Request->new('POST', "https://api.bitbucket.org/2.0/repositories/$owner/$repo/commit/$rev/statuses/build");
                $req->header('Content-Type' => 'application/json');
                $req->authorization_basic($bitbucket->{username}, $bitbucket->{password});
                $req->content($body);
                my $res = $ua->request($req);
                print STDERR $res->status_line, ": ", $res->decoded_content, "\n" unless $res->is_success;
            }
        }
    }
}

sub buildQueued {
    common(@_, [], 0);
}

sub buildStarted {
    common(@_, [], 0);
}

sub buildFinished {
    common(@_, 1);
}

1;
